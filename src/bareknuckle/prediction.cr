module Bareknuckle
  # One file that differs from the last build, as `punch dev` sends it
  # (`Punch::Bareknuckle::Edit`), with the new contents of a Crystal file
  # (`nil` when it is gone or is not Crystal).
  record Edit, path : String, kind : String, change : String, tier : String, content : String?

  # Which LLVM modules a round regenerates, predicted the way a warm
  # compiler would have to decide it.
  #
  # `before`: from the last round's map and the round's edits only, before
  # anything is typed: the functions that hold the code of each changed
  # method (its own, or the callers it is inlined into), the callers of a
  # method whose signature changed, `_main` for a change outside methods,
  # and every function with code on a changed line, or after one when
  # lines were added or removed: debug information records each line and
  # column, so a comment or a blank line moves the code after it.
  #
  # `retype`: what typing the dirty functions again adds, from the new
  # map: the functions they call that did not exist before (new
  # instantiations), the callers of a dirty function whose return type
  # changed, and the functions only they called, now gone.
  class Prediction
    # Every module: a full build.
    getter? all = false
    getter reasons = [] of String
    # The old map's dirty functions, by key.
    getter dirty = Set(String).new
    # The changed methods, for the log (`Owner#name`).
    getter methods = [] of String
    # After `retype`: the modules holding a function that a dirty function
    # calls, directly or not. Codegen adds a module's functions in the order
    # it first reaches them, depth first, so such a module can differ only
    # in that order.
    getter called = Set(String).new

    def initialize(@map : ProgramMap)
    end

    def all!(reason : String) : Nil
      @all = true
      @reasons << reason
    end

    # The modules of the old map's dirty functions.
    def modules : Set(String)
      @dirty.compact_map { |key| @map.functions[key]?.try(&.module_name) }.to_set
    end

    def self.before(map : ProgramMap, sources : Hash(String, String), edits : Array(Edit), root : String,
                    macro_files : Set(String), macro_commands : Set(String)) : Prediction
      prediction = new(map)
      edits.each do |edit|
        path = File.join(root, edit.path)
        if edit.tier == "full"
          prediction.all!("#{edit.path}: #{edit.change.tr("_", " ")} (#{edit.kind})")
        elsif macro_files.includes?(path) || macro_commands.any?(&.includes?(edit.path))
          prediction.all!("#{edit.path}: read by a macro")
        elsif edit.path.ends_with?(".cr") && edit.change.in?("body", "data", "signature")
          prediction.file(path, sources[path]?, edit.content, signature: edit.change == "signature")
        end
      end
      prediction
    end

    protected def file(path : String, before : String?, after : String?, signature : Bool) : Nil
      return all!("#{path}: not typed before") unless before && after

      changes = Punch::Bareknuckle::Fingerprint.methods(before, after) || return all!("#{path}: does not parse")
      changes.changed.each do |method|
        @methods << method.to_s
        lines = method.anchors.to_set << method.line
        matched = @map.functions.each_value.select { |function| function.origins.any? { |(file, first, _)| file == path && first.in?(lines) } }.to_a
        matched.each { |function| @dirty << function.key }
        # A changed signature may change which method a call resolves to.
        matched.each { |function| @map.callers[function.key]?.try { |callers| @dirty.concat(callers) } } if signature
      end
      @dirty << "__crystal_main" if changes.outside
      moved(path, before, after)
    end

    # Debug information records each function's lines and columns: every
    # function with code on a changed line differs, and when lines were
    # added or removed, every function after the first change.
    private def moved(path : String, before : String, after : String) : Nil
      old = before.lines
      new = after.lines
      first = (old.zip?(new).index { |(line, other)| line != other } || Math.min(old.size, new.size)) + 1
      same = 0
      while same < old.size - first + 1 && same < new.size - first + 1 && old[-1 - same] == new[-1 - same]
        same += 1
      end
      last = old.size == new.size ? old.size - same : Int32::MAX
      @map.functions.each_value do |function|
        @dirty << function.key if function.origins.any? { |(file, start, finish)| file == path && finish >= first && start <= last }
      end
    end

    # The modules after typing the dirty functions again in *new*, a map of
    # the edited program: `before`'s, plus what retyping finds.
    def retype(new : ProgramMap) : Set(String)
      modules = self.modules
      dirty = @dirty.dup
      queue = dirty.to_a
      fresh = Set(String).new
      while key = queue.pop?
        current = new.functions[key]? || @map.functions[key]?.try { |old| new.bases[old.base]?.try(&.first?) }
        unless new.functions.has_key?(key)
          # Gone, or typed with another return type: its callers change.
          @map.callers[key]?.try &.each { |caller| queue << caller if dirty.add?(caller) }
          @map.functions[key]?.try { |old| modules << old.module_name }
        end
        next unless current

        modules << current.module_name
        current.callees.each do |callee|
          next if @map.functions.has_key?(callee) || !fresh.add?(callee)

          queue << callee
          dirty << callee
        end
      end
      called(new, dirty)
      # Functions only dirty functions called, now gone.
      @map.functions.each_value do |old|
        next if new.functions.has_key?(old.key)

        callers = @map.callers[old.key]?
        modules << old.module_name if callers && !callers.empty? && callers.all? { |caller| dirty.includes?(caller) }
      end
      modules
    end

    private def called(new : ProgramMap, dirty : Set(String)) : Nil
      seen = Set(String).new
      queue = dirty.select { |key| new.functions.has_key?(key) }
      while key = queue.pop?
        new.functions[key].callees.each do |callee|
          next unless seen.add?(callee)

          function = new.functions[callee]? || next
          @called << function.module_name
          queue << callee
        end
      end
    end

    # How the modules a build regenerated (*rebuilt*, the compiler's
    # report) compare with *predicted* (`retype`), given the maps before
    # and after the edit.
    #
    # *types_changed* when the compiler's type IDs differ
    # (`Typing::Result#type_ids`): an added type renumbers the others, so
    # any module that checks types can differ in those numbers alone.
    def compare(predicted : Set(String), rebuilt : Array(String), old : ProgramMap, new : ProgramMap, types_changed : Bool = false) : Comparison
      hits, missed = rebuilt.partition { |name| predicted.includes?(name) }
      renumbered, missed = missed.partition { |name| Comparison.renumbered?(old, new, name) }
      same = ->(name : String) { old.modules[name]? == new.modules[name]? }
      reordered, missed = missed.partition { |name| @called.includes?(name) && same.call(name) }
      type_ids, misses = missed.partition { |name| types_changed && old.modules.has_key?(name) && same.call(name) }
      Comparison.new(hits, renumbered, reordered, type_ids, misses, old, new)
    end
  end

  # A prediction against the build (`Prediction#compare`): the rebuilt
  # modules it predicted (`hits`), the noise, and the `misses`.
  #
  # Noise is a module the build regenerated with the same code:
  # `renumbered`, which differs between the maps only in the compiler's
  # temporary names (numbered program-wide, so an added literal renumbers
  # the rest), and `reordered`, which the map sees no change in and which
  # holds a function a dirty function calls (`Prediction#called`), and
  # `type_ids`, which the map sees no change in, in a round whose types
  # changed.
  struct Comparison
    getter hits : Array(String)
    getter renumbered : Array(String)
    getter reordered : Array(String)
    getter type_ids : Array(String)
    getter misses : Array(String)

    def initialize(@hits, @renumbered, @reordered, @type_ids, @misses, @old : ProgramMap, @new : ProgramMap)
    end

    def self.renumbered?(old : ProgramMap, new : ProgramMap, name : String) : Bool
      before = old.modules[name]?
      after = new.modules[name]?
      !before.nil? && !after.nil? && before[0] != after[0] && before[1] == after[1]
    end

    # Why *name* is a miss, as far as the maps tell.
    def why(name : String) : String
      before = @old.modules[name]?
      after = @new.modules[name]?
      return "new module" unless before
      return "gone from the map" unless after
      return "the map sees no change" if before == after

      "changed"
    end
  end
end
