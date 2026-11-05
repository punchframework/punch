module Bareknuckle
  # What the fast path looks up in a typed program (`Warm`): each typed
  # method's calls, with the function each call's code is in, and the
  # methods as declared, by where they are declared. A walk from the main
  # code, the constants and the class variables, following each call to
  # the methods it targets, as codegen does.
  class Index < Crystal::Visitor
    # The function a call's code is in: a typed method, or the main module
    # (top-level code, constants, class variables, procs), or an instance
    # variable's initializer, which codegen puts wherever the type is
    # allocated.
    alias Encloser = Crystal::Def | Symbol

    # By file, line, column and name.
    alias Place = {String, Int32, Int32, String}

    getter calls = Hash(Crystal::Def, Hash(Crystal::Call, Encloser)).new.compare_by_identity
    @typed = Hash(Place, Array(Crystal::Def)).new
    @originals = Hash(Place, Crystal::Def).new
    @visited = Set(Crystal::ASTNode).new.compare_by_identity
    @stack = [:main] of Encloser

    def initialize(program : Crystal::Program, node : Crystal::ASTNode)
      node.accept(self)
      program.const_initializers.each(&.value.accept(self))
      program.class_var_initializers.each(&.node.accept(self))
      declared(program, Set(Crystal::Type).new)
      program.file_modules.each_value { |file_module| declared(file_module, Set(Crystal::Type).new) }
    end

    # The typed methods reached from the program.
    def instances : Array(Crystal::Def)
      @calls.keys
    end

    # The typed instances of *node*, a method as parsed from *path*.
    def instances(path : String, node : Crystal::Def) : Array(Crystal::Def)
      Index.place(path, node).try { |place| instances(place) } || [] of Crystal::Def
    end

    def instances(place : Place) : Array(Crystal::Def)
      @typed[place]? || [] of Crystal::Def
    end

    # The program's method declared as *node* in *path*.
    def original(path : String, node : Crystal::Def) : Crystal::Def?
      Index.place(path, node).try { |place| original(place) }
    end

    def original(place : Place) : Crystal::Def?
      @originals[place]?
    end

    def self.place(path : String, node : Crystal::Def) : Place?
      location = node.location || return
      filename = location.filename
      {filename, location.line_number, location.column_number, node.name} if filename.is_a?(String) && filename == path
    end

    # Whether codegen inlines a call of *target* instead of calling a
    # function (`CodeGenVisitor#try_inline_call`).
    def self.inlined?(target : Crystal::Def) : Bool
      return false if target.is_a?(Crystal::External)

      case body = target.body
      when Crystal::Nop, Crystal::NilLiteral, Crystal::BoolLiteral, Crystal::CharLiteral, Crystal::StringLiteral,
           Crystal::NumberLiteral, Crystal::SymbolLiteral, Crystal::InstanceVar
        true
      when Crystal::Var
        body.name == "self"
      else
        false
      end
    end

    private def declared(type : Crystal::Type, seen : Set(Crystal::Type)) : Nil
      return unless seen.add?(type)

      if type.is_a?(Crystal::ModuleType)
        type.defs.try &.each_value &.each do |metadata|
          definition = metadata
          while definition
            original = definition.def
            location = original.location
            if location && (filename = location.filename).is_a?(String)
              @originals[{filename, location.line_number, location.column_number, original.name}] = original
            end
            definition = original.previous
          end
        end
        declared(type.metaclass, seen)
      end
      type.types?.try &.each_value { |nested| declared(nested, seen) }
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    def visit(node : Crystal::Macro) : Bool
      false
    end

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

    def visit(node : Crystal::ClassDef) : Bool
      node.hook_expansions.try &.each(&.accept(self))
      node.resolved_type?.try &.instance_vars_initializers.try &.each do |initializer|
        within(:initializer) { initializer.value.accept(self) }
      end
      true
    end

    def visit(node : Crystal::ProcLiteral) : Bool
      within(:main) { node.def.body.accept(self) }
      false
    end

    def visit(node : Crystal::ProcPointer) : Bool
      node.call?.try(&.accept(self))
      true
    end

    def visit(node : Crystal::FunDef) : Bool
      if node.body && (external = node.external?)
        within(:main) { external.body.accept(self) } if @visited.add?(external)
      end
      false
    end

    def visit(node : Crystal::Call) : Bool
      if expanded = node.expanded
        expanded.accept(self)
        return false
      end

      node.obj.try(&.accept(self))
      node.args.each(&.accept(self))
      node.named_args.try(&.each(&.value.accept(self)))
      block = node.block
      node.target_defs.try &.each do |target|
        (@calls[target] ||= Hash(Crystal::Call, Encloser).new.compare_by_identity)[node] = @stack.last
        next unless @visited.add?(target)

        target.location.try do |location|
          filename = location.filename
          (@typed[{filename, location.line_number, location.column_number, target.name}] ||= [] of Crystal::Def) << target if filename.is_a?(String)
        end
        if (block && !target.uses_block_arg?) || Index.inlined?(target) || target.body.is_a?(Crystal::Primitive)
          target.body.accept(self)
        else
          within(target) { target.body.accept(self) }
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

    private def within(encloser : Encloser, &) : Nil
      @stack << encloser
      yield
    ensure
      @stack.pop
    end
  end
end
