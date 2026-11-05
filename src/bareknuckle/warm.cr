module Bareknuckle
  # A typed program kept warm after a build, and the fast path from it: an
  # edit that only changes method bodies re-types those methods in place,
  # generates only the LLVM modules holding them, and links the rest from
  # the object cache.
  #
  # Anything else is refused (`Refused`), so `punch dev` builds the app
  # in full: a changed signature or code outside methods, a method that
  # yields, a return type, instance variable or type that changes, new
  # symbols, and anything that needs the main module (constants, class
  # variables, procs, top-level code). A refusal after the program was
  # touched spoils it (`Refused#spoiled?`): it then needs a new process.
  class Warm
    class Refused < Exception
      getter? spoiled : Bool

      def initialize(message : String, @spoiled : Bool = false)
        super(message)
      end
    end

    # A round on the fast path: the stage times, in the shape of
    # `crystal build --stats`, and the modules generated again.
    record Patched, stats : String, modules : Array(String), methods : Array(String)

    getter compiler : Crystal::Compiler
    getter program : Crystal::Program
    # The app's files as typed, by absolute path.
    getter sources : Hash(String, String)
    @node : Crystal::ASTNode
    @emitted : Emitted
    @output : String
    @type_ids : String
    @symbols : Int32
    @index : Index? = nil

    def initialize(@compiler, @program, @node, @emitted, @sources, @output)
      @type_ids = Crystal::LLVMId.new(@program).digest
      @symbols = @program.symbols.size
    end

    # Builds *main* as `crystal build` does, into *output*, recording what
    # codegen generates; with *stats*, printing the stage times as
    # `--stats` does. Raises `Crystal::CodeError` or `Crystal::Error`
    # when it does not build.
    def self.build(main : String, flags : Array(String), output : String, link_flags : String?, stats : Bool = true) : Warm
      Sources.overlay = {} of String => String
      Sources.read.clear
      Instances.clear
      compiler = Crystal::Compiler.new
      compiler.color = false
      compiler.progress_tracker.stats = stats
      compiler.link_flags = link_flags
      flags.each { |flag| compiler.flags << flag }
      emitted = Emitted.new
      Emit.recording = emitted
      result = begin
        compiler.compile(Crystal::Compiler::Source.new(main, Sources.read(main)), output)
      ensure
        Emit.recording = nil
      end
      warm = new(compiler, result.program, result.node, emitted, Sources.read.dup, output)
      Warm.release
      warm
    end

    # Frees what codegen left behind (its LLVM modules are freed when
    # collected) and gives the memory back: a build's peak is about twice
    # what the typed program keeps.
    def self.release : Nil
      GC.collect
      {% if flag?(:linux) && flag?(:gnu) %}
        LibC.malloc_trim(0)
      {% end %}
    end

    # The process's resident memory, in MB.
    def self.rss_mb : Int32
      {% if flag?(:linux) %}
        File.each_line("/proc/self/status") do |line|
          return line.split[1].to_i // 1024 if line.starts_with?("VmRSS:")
        end
      {% end %}
      (GC.stats.heap_size // 1024 // 1024).to_i
    end

    # The object cache the build wrote to.
    def directory : String
      @emitted.directory
    end

    # Walks the typed program for the next round, once (about a second
    # on the reference app).
    def index : Index
      @index ||= Index.new(@program, @node)
    end

    # The fast path for *edits* (new contents by absolute path).
    def patch(edits : Hash(String, String)) : Patched
      started = Time.instant
      index = self.index
      changes = edits.flat_map { |path, content| Changes.of(@program, path, @sources[path]? || raise(Refused.new("#{path}: not typed before")), content) }
      raise Refused.new("nothing to type again") if changes.empty?

      originals = changes.map do |change|
        index.original(change.path, change.before) || raise(Refused.new("#{change.name} (#{change.path}:#{change.before.location.try(&.line_number)}): not found as written, it may come from a macro"))
      end
      old, news = instances(changes, originals, index)

      # From here on the program changes.
      replaced, calls = retype(changes, originals, news, old, index)
      typed = Time.instant
      dirty = dirty_modules(old, replaced, calls)
      modules, partial = Emit.generate(@program, @node, @compiler, @emitted, dirty, replaced)
      generated = Time.instant
      stages = [{"Semantic (bareknuckle)", (typed - started).total_seconds}, {"Codegen (crystal)", (generated - typed).total_seconds}]
      units = @compiler.bareknuckle_link(@program, modules, @emitted.objects, @emitted.directory, @output) do |stage, seconds|
        stages << {stage, seconds}
      end
      @emitted.replace(partial.emitted, modules.keys)
      changes.each { |change| @sources[change.path] = change.content }
      @index = nil
      Patched.new(Warm.stats(stages, units, @emitted.objects.size), modules.keys.map { |name| name.empty? ? "_main" : name }.sort!,
        changes.map(&.name))
    rescue ex : Emit::NeedsFull
      raise Refused.new(ex.message || "needs a full build", spoiled: true)
    rescue ex : Crystal::CodeError
      ex.color = false
      STDERR.puts "bareknuckle: typing again failed:\n#{ex}" if ENV["BAREKNUCKLE_DEBUG"]?
      raise Refused.new("typing again failed: #{ex.message.try(&.lines.first?)}", spoiled: true)
    end

    # The typed instances of the changed methods, and the `new` the
    # compiler made from each changed `initialize` (which carries its
    # place) with that `initialize`.
    private def instances(changes : Array(Changes::Change), originals : Array(Crystal::Def),
                          index : Index) : {Set(Crystal::Def), Array({Crystal::Def, Crystal::Def})}
      old = Set(Crystal::Def).new.compare_by_identity
      changes.each { |change| index.instances(change.path, change.before).each { |instance| old << instance } }
      # Instances of expansions (default and named arguments) are placed
      # elsewhere, but cached under the method they expand.
      Instances.of(originals).each { |instance| old << instance }
      news = [] of {Crystal::Def, Crystal::Def}
      changes.zip(originals) do |change, original|
        next unless change.name == "initialize"

        place = Index.place(change.path, change.before).try { |(file, line, column, _)| {file, line, column, "new"} } || next
        index.original(place).try do |made|
          news << {made, original}
          Instances.of([made]).each { |instance| old << instance }
        end
        index.instances(place).each { |instance| old << instance }
      end
      old.each do |instance|
        raise Refused.new("#{instance.owner}##{instance.name} yields to a block") if instance.block_arg || instance.block_arity
      end
      {old, news}
    end

    # Puts the new bodies in place and types every call of the changed
    # methods again (`Crystal::Call#recalculate`, as the compiler does
    # when an argument's type changes). Returns the old typed methods
    # with their replacements, and the calls with the function they are in.
    private def retype(changes : Array(Changes::Change), originals : Array(Crystal::Def), news : Array({Crystal::Def, Crystal::Def}),
                       old : Set(Crystal::Def), index : Index) : {Hash(Crystal::Def, Crystal::Def), Array({Crystal::Call, Index::Encloser})}
      changes.zip(originals) do |change, original|
        normalized = @program.normalize(change.after).as?(Crystal::Def) || raise(Refused.new("#{change.name}: not a plain method after normalizing", spoiled: true))
        original.body = normalized.body
        original.location = normalized.location
        original.end_location = normalized.end_location
      end
      news.each do |(made, initialize)|
        again = initialize.expand_new_from_initialize(made.owner.instance_type)
        made.body = again.body
        made.location = again.location
        made.end_location = again.end_location
      end
      old.each { |instance| Instances.evict(instance) }

      calls = old.flat_map { |instance| index.calls[instance]?.try(&.to_a) || [] of {Crystal::Call, Index::Encloser} }.uniq! { |(call, _)| call.object_id }
      replaced = Hash(Crystal::Def, Crystal::Def).new.compare_by_identity
      calls.each { |(call, _)| recalculate(call, old, replaced) }

      fixer = Crystal::FixMissingTypes.new(@program)
      fixer.bareknuckle_fixed(index.instances)
      cleanup = @program.cleanup_transformer
      calls.each do |(call, _)|
        call.accept(fixer)
        cleanup.bareknuckle_clean(call)
      end
      replaced.each do |target, now|
        raise Refused.new("#{target.owner}##{target.name} now raises differently", spoiled: true) unless now.raises? == target.raises?
      end

      raise Refused.new("types were added", spoiled: true) unless Crystal::LLVMId.new(@program).digest == @type_ids
      raise Refused.new("symbols were added", spoiled: true) unless @program.symbols.size == @symbols

      {replaced, calls}
    end

    # Types *call* again, and notes in *replaced* the new instance of each
    # of its targets that is in *old*.
    private def recalculate(call : Crystal::Call, old : Set(Crystal::Def), replaced : Hash(Crystal::Def, Crystal::Def)) : Nil
      before = call.type?
      targets = call.target_defs.try(&.dup) || [] of Crystal::Def
      raise Refused.new("a call with a block (#{call})", spoiled: true) if call.block
      reshaped = Reshaped.restore(call)
      call.recalculate
      Reshaped.reapply(call) if reshaped
      after = call.target_defs || [] of Crystal::Def
      if call.type? != before || after.size != targets.size
        raise Refused.new("the type of `#{call}` changed (tier 2, not attempted)", spoiled: true)
      end
      targets.zip(after) do |target, now|
        next if target.same?(now)
        raise Refused.new("#{target.owner}##{target.name} now returns #{now.type?}, not #{target.type?}", spoiled: true) unless now.type? == target.type?
        raise Refused.new("#{target.owner}##{target.name}'s closure changed", spoiled: true) unless now.closure? == target.closure? && now.self_closured? == target.self_closured?

        replaced[target] = now if old.includes?(target)
      end
    end

    # The modules to generate again: where the changed methods were, and
    # where a call of one is inlined (a body that is a literal, `self` or
    # an instance variable). Modules of new instantiations join while
    # generating (`Emit.generate`).
    private def dirty_modules(old : Set(Crystal::Def), replaced : Hash(Crystal::Def, Crystal::Def),
                              calls : Array({Crystal::Call, Index::Encloser})) : Set(String)
      dirty = Set(String).new
      old.each do |instance|
        modules = @emitted.modules_of(instance)
        next if modules.empty?
        raise Refused.new("#{instance.owner}##{instance.name} was not typed again", spoiled: true) unless replaced.has_key?(instance)

        dirty.concat(modules)
      end
      calls.each do |(call, encloser)|
        next unless call.target_defs.try(&.any? { |target| Index.inlined?(target) }) ||
                    old.any? { |instance| Index.inlined?(instance) && call.target_defs.try(&.any?(&.same?(instance))) }

        case encloser
        when Crystal::Def
          dirty.concat(@emitted.modules_of(encloser))
        else
          raise Refused.new("a changed method is inlined into #{encloser == :main ? "the main module" : "an instance variable's initializer"}", spoiled: true)
        end
      end
      dirty
    end

    # *stages* and *units* as `crystal build --stats` prints them, so
    # `punch dev`'s round log reads both alike (`Punch::Bareknuckle::Stats`).
    def self.stats(stages : Array({String, Float64}), units : Array(Crystal::Compiler::CompilationUnit), total : Int32) : String
      heap = GC.stats.heap_size / 1024.0 / 1024.0
      String.build do |io|
        stages.each do |(name, seconds)|
          span = Time::Span.new(nanoseconds: (seconds * 1e9).to_i64)
          io << "#{name}:".ljust(34) << ' ' << span.to_s.rjust(18, '0') << " (" << heap.round(2).to_s.rjust(8) << "MB)\n"
        end
        rebuilt = units.reject(&.reused_previous_compilation?)
        io << "\nCodegen (bc+obj):\n"
        if rebuilt.empty?
          io << " - all previous .o files were reused\n"
        else
          io << " - " << total - rebuilt.size << '/' << total << " .o files were reused\n\nThese modules were not reused:\n"
          rebuilt.each { |unit| io << " - " << unit.original_name << " (" << unit.name << ".bc)\n" }
        end
      end
    end
  end

  # The arguments of calls with named arguments or splats as typed: the
  # compiler's cleanup turns them into positional arguments afterwards,
  # and a call must have them back to be typed again.
  module Reshaped
    @@calls = Hash(Crystal::Call, {Array(Crystal::ASTNode), Array(Crystal::NamedArgument)?}).new.compare_by_identity

    def self.save(call : Crystal::Call) : Nil
      return unless call.named_args || call.args.any? { |arg| arg.is_a?(Crystal::Splat | Crystal::DoubleSplat) }

      @@calls[call] ||= {call.args.dup, call.named_args.dup}
    end

    # Gives *call* its arguments as typed; whether it had others.
    def self.restore(call : Crystal::Call) : Bool
      args, named_args = @@calls[call]? || return false
      call.args = args.dup
      call.named_args = named_args.dup
      true
    end

    # What the cleanup does to *call* (`CleanupTransformer#transform`).
    def self.reapply(call : Crystal::Call) : Nil
      call.replace_splats
      if named_args = call.named_args
        named_args.each { |named_arg| call.args << named_arg.value }
        call.named_args = nil
      end
    end
  end

  # Where the compiler cached each typed method (`add_def_instance`), so
  # a changed method's instances can be dropped from the cache.
  module Instances
    @@cached = Hash(Crystal::Def, {Crystal::DefInstanceContainer, Crystal::DefInstanceKey}).new.compare_by_identity

    def self.add(container : Crystal::DefInstanceContainer, key : Crystal::DefInstanceKey, typed_def : Crystal::Def) : Nil
      @@cached[typed_def] = {container, key}
    end

    # The cached instances of *originals*, expansions included.
    def self.of(originals : Array(Crystal::Def)) : Array(Crystal::Def)
      ids = originals.map(&.object_id).to_set
      @@cached.compact_map { |typed_def, (_, key)| typed_def if ids.includes?(key.def_object_id) }
    end

    def self.evict(typed_def : Crystal::Def) : Nil
      if entry = @@cached.delete(typed_def)
        container, key = entry
        container.def_instances.delete(key)
      end
    end

    def self.clear : Nil
      @@cached.clear
    end
  end
end

lib LibC
  {% if flag?(:linux) && flag?(:gnu) %}
    fun malloc_trim(pad : SizeT) : Int
  {% end %}
end

module Crystal
  module DefInstanceContainer
    def add_def_instance(key, typed_def)
      # bareknuckle: remembers where it is cached.
      Bareknuckle::Instances.add(self, key, typed_def)
      previous_def
    end
  end

  class FixMissingTypes
    # bareknuckle: methods already fixed, which a round does not visit again.
    def bareknuckle_fixed(defs : Enumerable(Def)) : Nil
      defs.each { |typed_def| @fixed << typed_def }
    end
  end

  class CleanupTransformer
    def transform(node : Call)
      # bareknuckle: the arguments before the cleanup changes them.
      Bareknuckle::Reshaped.save(node)
      previous_def
    end

    # bareknuckle: cleans up the methods a call targets after it was typed
    # again, as `transform(Call)` does for each target.
    def bareknuckle_clean(call : Call) : Nil
      call.target_defs.try &.each do |target_def|
        next unless @transformed.add?(target_def)

        current_def = @current_def
        call.bubbling_exception do
          @current_def = target_def
          @def_nest_count += 1
          target_def.body = target_def.body.transform(self)
          @def_nest_count -= 1
          @current_def = current_def
        end
      end
    end
  end
end
