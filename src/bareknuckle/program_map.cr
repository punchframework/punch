require "digest/sha256"
require "json"

module Bareknuckle
  # Where code comes from in the app: an absolute file name and its first
  # and last line, after following macro expansions back to the call that
  # made them.
  alias Origin = {String, Int32, Int32}

  # A function as codegen emits it (`Crystal::CodeGenVisitor`): a typed
  # method, a proc literal, a `fun`, a constant's or class variable's
  # initializer, or the program's top-level code (`__crystal_main`).
  class Function
    include JSON::Serializable

    # Stable across rounds while the function stays the same: owner, name,
    # argument types, and return type.
    getter key : String
    # The key without the return type: the same method, typed again.
    getter base : String
    # The LLVM module it goes into: its owner's instance type, by name, or
    # `_main` (`CodeGenVisitor#type_module`).
    getter module_name : String
    # Where the method itself is declared.
    getter own : Origin?
    # Where its code comes from: its own method and the methods inlined
    # into it (blocks are inlined with the method that yields), in the
    # app only.
    getter origins = Set(Origin).new
    getter callees = Set(String).new
    # Digests of its typed code, node by node, as is and with the names the
    # compiler numbers program-wide alike (temporaries, `__temp_…`, and
    # macro expansions in error messages), and of its callees.
    property raw = ""
    property normalized = ""

    # FNV-1a, which needs no allocation per node.
    OFFSET = 14695981039346656037_u64
    PRIME  =        1099511628211_u64

    @[JSON::Field(ignore: true)]
    @raw_hash = OFFSET
    @[JSON::Field(ignore: true)]
    @normalized_hash = OFFSET

    def initialize(@key : String, @module_name : String, @own : Origin?, base : String? = nil)
      @base = base || @key
      @own.try { |origin| @origins << origin }
    end

    # Adds *token* of its code; a *temporary* name counts as `__temp` in
    # the normalized digest, and *normalized* in place of *token*.
    def feed(token : String, temporary : Bool = false) : Nil
      feed(token, temporary ? "__temp" : token)
    end

    def feed(token : String, normalized : String) : Nil
      @raw_hash = Function.fnv(@raw_hash, token)
      @normalized_hash = Function.fnv(@normalized_hash, normalized)
    end

    def self.fnv(hash : UInt64, token : String) : UInt64
      token.each_byte { |byte| hash = (hash ^ byte) &* PRIME }
      (hash ^ 0xff_u64) &* PRIME
    end

    protected def finish : Nil
      callees.to_a.sort!.each { |callee| feed(callee) }
      @raw = @raw_hash.to_s(16)
      @normalized = @normalized_hash.to_s(16)
    end
  end

  # The functions of a typed program and the modules they go into, from a
  # walk of the typed tree that follows each call to its target methods,
  # as codegen does: what a build of the program would generate, without
  # generating it.
  class ProgramMap
    MAIN = "_main"

    getter functions = {} of String => Function
    # The functions by `Function#base`.
    getter bases = Hash(String, Array(Function)).new { |hash, key| hash[key] = [] of Function }
    # For each function, the functions that call it.
    getter callers = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
    # Each module's digests (`Function#raw`, `#normalized`), from its
    # functions'.
    getter modules = {} of String => {String, String}

    def self.build(result : Crystal::Compiler::Result, root : String) : ProgramMap
      map = new
      Walker.new(map, result.program, root).walk(result.node)
      map.functions.each_value(&.finish)
      map.index
      map
    end

    def self.new(pull : JSON::PullParser) : ProgramMap
      new(Array(Function).new(pull))
    end

    # A map of *functions*, as a typing worker sent them (`to_json`).
    def self.new(functions : Array(Function)) : ProgramMap
      map = new
      functions.each { |function| map.functions[function.key] = function }
      map.index
      map
    end

    def to_json(json : JSON::Builder) : Nil
      json.array { functions.each_value(&.to_json(json)) }
    end

    # What follows from the functions: bases, callers, and modules.
    protected def index : Nil
      functions.each_value do |function|
        bases[function.base] << function
        function.callees.each { |callee| callers[callee] << function.key }
      end
      functions.values.group_by(&.module_name).each do |name, functions|
        functions.sort_by!(&.key)
        raw = Digest::SHA256.hexdigest(functions.join('\n') { |function| "#{function.key} #{function.raw}" })
        normalized = Digest::SHA256.hexdigest(functions.join('\n') { |function| "#{function.key} #{function.normalized}" })
        @modules[name] = {raw, normalized}
      end
    end

    # The module codegen puts *type*'s methods into.
    def self.module_name(type : Crystal::Type) : String
      type = type.remove_typedef
      return MAIN if type.is_a?(Crystal::Program) || type.is_a?(Crystal::LibType)

      type.instance_type.to_s.presence || MAIN
    end
  end

  private class Walker < Crystal::Visitor
    @stack = [] of Function
    @visited = Set(Crystal::ASTNode).new.compare_by_identity
    @procs = Hash(String, Int32).new(0)

    @shards : String

    def initialize(@map : ProgramMap, @program : Crystal::Program, @root : String)
      @shards = "#{@root}lib/"
    end

    def walk(main : Crystal::ASTNode) : Nil
      within(function("__crystal_main", ProgramMap::MAIN, nil)) { main.accept(self) }
      @program.const_initializers.each do |const|
        within(function("const #{const}", ProgramMap::MAIN, origin(const.locations.try(&.first?), nil))) { const.value.accept(self) }
      end
      @program.class_var_initializers.each do |initializer|
        within(function("class var #{initializer.owner}#{initializer.name}", ProgramMap::MAIN, origin(initializer.node))) do
          initializer.node.accept(self)
        end
      end
    end

    def visit(node : Crystal::ASTNode) : Bool
      place(node)
      token(node)
      true
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end

    # Macro hooks (`inherited`, `included`, `extended`, `method_added`)
    # expand beside the node that triggered them.
    def visit(node : Crystal::Def) : Bool
      node.hook_expansions.try &.each(&.accept(self))
      false
    end

    def visit(node : Crystal::Include | Crystal::Extend) : Bool
      node.hook_expansions.try &.each(&.accept(self))
      true
    end

    def visit(node : Crystal::ExpandableNode) : Bool
      return false unless @visited.add?(node)

      node.expanded.try(&.accept(self))
      true
    end

    def visit(node : Crystal::Call) : Bool
      place(node)
      token(node)
      if expanded = node.expanded
        expanded.accept(self)
        return false
      end

      node.obj.try(&.accept(self))
      node.args.each(&.accept(self))
      node.named_args.try(&.each(&.value.accept(self)))
      block = node.block
      node.target_defs.try &.each do |target|
        if block && !target.uses_block_arg?
          # Inlined: the method's body and the block become part of this
          # function.
          origin(target).try { |origin| current.origins << origin }
          target.body.accept(self) if @visited.add?(target)
        else
          call(target)
        end
      end
      if block
        if literal = block.fun_literal
          literal.accept(self)
        elsif @visited.add?(block)
          block.body.accept(self)
        end
      end
      false
    end

    def visit(node : Crystal::ProcLiteral) : Bool
      # Codegen puts every proc literal (and captured block) in `_main`,
      # named after its file and line.
      outer = current
      @procs[outer.key] += 1
      literal = function("#{outer.base} -> #{@procs[outer.key]}", ProgramMap::MAIN, origin(node))
      outer.own.try { |origin| literal.origins << origin }
      outer.callees << literal.key
      within(literal) { node.def.body.accept(self) }
      false
    end

    def visit(node : Crystal::ProcPointer) : Bool
      node.call?.try(&.accept(self))
      true
    end

    def visit(node : Crystal::FunDef) : Bool
      if node.body && (external = node.external?)
        external_fun = function("fun #{node.real_name}", ProgramMap::MAIN, origin(node))
        within(external_fun) { external.body.accept(self) } if @visited.add?(external)
      end
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      node.hook_expansions.try &.each(&.accept(self))
      # Instance variable initializers (`@count = 0` in the class body)
      # are generated into the type's allocation.
      type = node.resolved_type? || return true
      type.instance_vars_initializers.try &.each do |initializer|
        name = ProgramMap.module_name(type)
        within(function("ivars #{type} #{initializer.name}", name, origin(initializer.value))) do
          initializer.value.accept(self)
        end
      end
      true
    end

    private def call(target : Crystal::Def) : Nil
      # Codegen inlines primitives (`Pointer#value`, `Tuple#[]`) and
      # trivial bodies: nothing, a literal, `self`, or one instance variable
      # (`CodeGenVisitor#try_inline_call`).
      if Walker.inlined?(target)
        origin(target).try { |origin| current.origins << origin }
        target.body.accept(self)
        return
      end

      owner = target.owner
      base = String.build do |io|
        io << owner << '#' << target.name
        next_def = target.next
        while next_def
          io << '\''
          next_def = next_def.next
        end
        io << '(' << target.args.join(", ", &.type?.to_s) << ')'
        target.block_arg.try { |arg| io << " &" << arg.type?.to_s } if target.uses_block_arg?
      end
      key = "#{base} : #{target.type?}"
      callee = @map.functions[key] ||= Function.new(key, ProgramMap.module_name(owner), origin(target), base)
      current.callees << key
      return unless @visited.add?(target)

      within(callee) { target.body.accept(self) }
    end

    MACRO = /macro_\d+/

    # What the digests of the current function take from *node*: its kind,
    # and its name or value.
    private def token(node : Crystal::ASTNode) : Nil
      function = current
      function.feed(node.class.name)
      case node
      when Crystal::Var, Crystal::Arg
        function.feed(node.name, node.name.starts_with?("__temp_"))
      when Crystal::InstanceVar, Crystal::ClassVar, Crystal::Global, Crystal::Call
        function.feed(node.name)
      when Crystal::NumberLiteral
        function.feed(node.value)
        function.feed(node.kind.to_s)
      when Crystal::StringLiteral
        # Error messages for code a macro expanded name the expansion by
        # an address (`macro_281472428840064`), which moves with the
        # compiler's allocations.
        value = node.value
        value.includes?("macro_") ? function.feed(value, value.gsub(MACRO, "macro_")) : function.feed(value)
      when Crystal::SymbolLiteral
        function.feed(node.value)
      when Crystal::CharLiteral, Crystal::BoolLiteral
        function.feed(node.value.to_s)
      when Crystal::Path
        node.names.each { |name| function.feed(name) }
      end
    end

    # Top-level code, which runs in `_main`, is placed by line.
    private def place(node : Crystal::ASTNode) : Nil
      return unless @stack.size == 1
      # Declarations hold code but are none themselves.
      return if node.is_a?(Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef | Crystal::Expressions |
                           Crystal::FileNode | Crystal::Require | Crystal::Alias | Crystal::Annotation | Crystal::Nop)

      origin(node).try { |origin| current.origins << origin }
    end

    def self.inlined?(target : Crystal::Def) : Bool
      return false if target.is_a?(Crystal::External)

      case body = target.body
      when Crystal::Primitive, Crystal::Nop, Crystal::NilLiteral, Crystal::BoolLiteral, Crystal::CharLiteral,
           Crystal::StringLiteral, Crystal::NumberLiteral, Crystal::SymbolLiteral, Crystal::InstanceVar
        true
      when Crystal::Var
        body.name == "self"
      else
        false
      end
    end

    private def current : Function
      @stack.last
    end

    private def function(key : String, module_name : String, own : Origin?) : Function
      @map.functions[key] ||= Function.new(key, module_name, own)
    end

    private def within(function : Function, &) : Nil
      @stack << function
      yield
    ensure
      @stack.pop
    end

    private def origin(node : Crystal::ASTNode) : Origin?
      origin(node.location, node.end_location)
    end

    # From *location* to *end_location* in the app, following macro
    # expansions to their call.
    private def origin(location : Crystal::Location?, end_location : Crystal::Location?) : Origin?
      while location
        case filename = location.filename
        when String
          return if !filename.starts_with?(@root) || filename.starts_with?(@shards)

          last = end_location.try { |finish| finish.line_number if finish.filename == filename } || location.line_number
          return {filename, location.line_number, last}
        when Crystal::VirtualFile
          location = filename.expanded_location
          end_location = nil
        else
          return
        end
      end
    end
  end
end
