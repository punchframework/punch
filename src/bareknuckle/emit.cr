module Bareknuckle
  # What codegen put into each LLVM module of the last build, so that a
  # round can generate some modules again and link them with the others'
  # object files.
  #
  # Modules are named as `Crystal::CodeGenVisitor#type_module` names them:
  # the owner's instance type, `""` for the main module.
  class Emitted
    # A function codegen generated: what `CodeGenVisitor#target_def_fun`
    # needs to generate it again.
    record Function, mangled : String, target : Crystal::Def, self_type : Crystal::Type

    # The functions each module holds, in the order codegen generated them.
    getter modules = {} of String => Array(Function)
    # The functions and globals each module defines, by name.
    getter defined = {} of String => Set(String)
    # Each module's object file, in the cache directory.
    getter objects = {} of String => String
    # The name of each proc literal's function. Codegen numbers procs
    # with the same type and place in the order it reaches them, so a
    # round, which reaches fewer, must reuse the names.
    getter procs = Hash(Crystal::ProcLiteral, String).new.compare_by_identity
    getter directory = ""

    # Where each typed method went: its modules.
    @placed : Hash(Crystal::Def, Set(String))? = nil

    def record(name : String, function : Function) : Nil
      (@modules[name] ||= [] of Function) << function
      @placed.try { |placed| (placed[function.target] ||= Set(String).new) << name }
    end

    # The modules codegen put *target* into; empty when it generated no
    # function for it (inlined, or not reached).
    def modules_of(target : Crystal::Def) : Set(String)
      placed = @placed ||= begin
        index = Hash(Crystal::Def, Set(String)).new.compare_by_identity
        @modules.each { |name, functions| functions.each { |function| (index[function.target] ||= Set(String).new) << name } }
        index
      end
      placed[target]? || Set(String).new
    end

    # Reads what *modules* define, after codegen wrote them.
    def define(modules : Hash(String, Crystal::CodeGenVisitor::ModuleInfo)) : Nil
      modules.each { |name, info| @defined[name] = Emitted.definitions(info.mod) }
    end

    def units(directory : String, units : Array(Crystal::Compiler::CompilationUnit)) : Nil
      @directory = directory
      units.each { |unit| @objects[unit.original_name == "_main" ? "" : unit.original_name] = unit.object_filename }
    end

    # Replaces what *modules* hold with what a round generated again.
    def replace(generated : Emitted, modules : Enumerable(String)) : Nil
      modules.each do |name|
        @modules[name] = generated.modules[name]? || [] of Function
        generated.defined[name]?.try { |names| @defined[name] = names }
      end
      @placed = nil
    end

    def self.definitions(mod : LLVM::Module) : Set(String)
      names = Set(String).new
      mod.functions.each { |function| names << function.name unless LibLLVM.is_declaration(function) != 0 }
      global = LibLLVM.get_first_global(mod)
      until global.null?
        names << String.new(LibLLVM.get_value_name2(global, out size), size) unless LibLLVM.is_declaration(global) != 0
        global = LibLLVM.get_next_global(global)
      end
      names
    end
  end

  # Code generation for one round: records what a full build generates
  # (`recording`), or generates only some modules (`partial`), giving
  # every function of the other modules a body that does nothing
  # (`Crystal::Unreachable`), since only its declaration is needed.
  module Emit
    class_property recording : Emitted? = nil
    class_property partial : Partial? = nil

    class Partial
      getter dirty : Set(String)
      # What the round generates, for the dirty modules.
      getter emitted = Emitted.new
      # The functions declared from the other modules, by module.
      getter stubbed = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
      getter stub : Crystal::Unreachable
      getter procs : Hash(Crystal::ProcLiteral, String)

      def initialize(@dirty : Set(String), program : Crystal::Program, @procs)
        @stub = Crystal::Unreachable.new
        @stub.type = program.no_return
      end
    end

    class NeedsFull < Exception
    end

    # The `fun` definitions with a body in the main code.
    private class FunDefs < Crystal::Visitor
      getter all = [] of Crystal::FunDef

      def visit(node : Crystal::FunDef) : Bool
        @all << node
        false
      end

      def visit(node : Crystal::Def | Crystal::Macro) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end

    # Generates *dirty*'s modules again from *emitted* (the last build),
    # with *replaced* typed methods in place of the old ones. Modules that
    # turn out to need a function they did not hold join the dirty ones;
    # the main module never does, since its contents (constants, class
    # variables, procs) are generated as code first reaches them: a round
    # that needs it raises `NeedsFull`.
    def self.generate(program : Crystal::Program, node : Crystal::ASTNode, compiler : Crystal::Compiler, emitted : Emitted,
                      dirty : Set(String), replaced : Hash(Crystal::Def, Crystal::Def)) : {Hash(String, Crystal::CodeGenVisitor::ModuleInfo), Partial}
      raise NeedsFull.new("the main module changed") if dirty.includes?("")

      funs = FunDefs.new
      node.accept(funs)
      loop do
        # Codegen marks each `fun` it generated, so it never does twice.
        funs.all.each { |fun_def| fun_def.external?.try(&.dead = false) }
        partial = Partial.new(dirty.dup, program, emitted.procs)
        @@partial = partial
        visitor = Crystal::CodeGenVisitor.new(program, node, debug: compiler.debug, frame_pointers: compiler.frame_pointers)
        dirty.each do |name|
          emitted.modules[name]?.try &.each do |function|
            visitor.target_def_fun(replaced[function.target]? || function.target, function.self_type)
          end
        end
        visitor.finish
        @@partial = nil

        main = Emitted.definitions(visitor.modules[""].mod)
        unless main.subset_of?(emitted.defined[""]? || Set(String).new)
          raise NeedsFull.new("the main module needs #{(main - (emitted.defined[""]? || Set(String).new)).first(3).join(", ")}")
        end
        missing = partial.stubbed.select { |name, names| !names.subset_of?(emitted.defined[name]? || Set(String).new) }.keys
        if missing.empty?
          partial.emitted.define(visitor.modules.select { |name, _| dirty.includes?(name) })
          return {visitor.modules.select { |name, _| dirty.includes?(name) }, partial}
        end
        raise NeedsFull.new("the main module changed") if missing.includes?("")

        dirty.concat(missing)
      end
    ensure
      @@partial = nil
    end
  end
end

lib LibLLVM
  fun is_declaration = LLVMIsDeclaration(global : ValueRef) : Int32
  fun get_first_global = LLVMGetFirstGlobal(m : ModuleRef) : ValueRef
  fun get_next_global = LLVMGetNextGlobal(global : ValueRef) : ValueRef
  fun get_value_name2 = LLVMGetValueName2(val : ValueRef, length : LibC::SizeT*) : LibC::Char*
  fun get_debug_loc_line = LLVMGetDebugLocLine(val : ValueRef) : UInt32
  fun get_debug_loc_column = LLVMGetDebugLocColumn(val : ValueRef) : UInt32
end

module Crystal
  class CodeGenVisitor
    def codegen_fun(mangled_name, target_def, self_type, is_exported_fun = false, fun_module_info = type_module(self_type), is_fun_literal = false, is_closure = false)
      # bareknuckle: which module, by `type_module`'s name.
      name = fun_module_info.mod == @main_mod ? "" : fun_module_info.mod.name
      replayable = !is_exported_fun && !is_fun_literal && !is_closure && !target_def.is_a?(External)
      if partial = Bareknuckle::Emit.partial
        if partial.dirty.includes?(name)
          partial.emitted.record(name, Bareknuckle::Emitted::Function.new(mangled_name, target_def, self_type)) if replayable
        elsif replayable
          # Only its declaration is needed: generate it with a body that
          # does nothing, then put the real one back.
          partial.stubbed[name] << mangled_name
          real = target_def.body # ameba:disable Lint/UselessAssign
          target_def.body = partial.stub
          begin
            return previous_def(mangled_name, target_def, self_type, is_exported_fun, fun_module_info, is_fun_literal, is_closure)
          ensure
            target_def.body = real
          end
        end
      elsif replayable
        Bareknuckle::Emit.recording.try(&.record(name, Bareknuckle::Emitted::Function.new(mangled_name, target_def, self_type)))
      end
      previous_def(mangled_name, target_def, self_type, is_exported_fun, fun_module_info, is_fun_literal, is_closure)
    end
  end

  class CodeGenVisitor
    def fun_literal_name(node : ProcLiteral)
      # bareknuckle: the name the full build gave it.
      if partial = Bareknuckle::Emit.partial
        return partial.procs[node]? || raise Bareknuckle::Emit::NeedsFull.new("a proc is new to the main module")
      end
      name = previous_def
      Bareknuckle::Emit.recording.try(&.procs.[]=(node, name))
      name
    end
  end

  class Program
    def codegen(node, single_module = false, debug = Debug::Default, frame_pointers = FramePointers::Auto)
      modules = previous_def
      # bareknuckle: what each module defines, before it is written.
      Bareknuckle::Emit.recording.try(&.define(modules))
      modules
    end
  end

  class Compiler
    private def codegen(program, units : Array(CompilationUnit), output_filename, output_dir)
      # bareknuckle: each module's object file.
      Bareknuckle::Emit.recording.try(&.units(output_dir, units))
      previous_def
    end

    # bareknuckle: compiles *modules* (a round's dirty ones) into the
    # cache directory as a build does, and links them with the other
    # modules' object files (*objects*) into *output_filename*. Returns
    # the units, to tell which were reused.
    def bareknuckle_link(program : Program, modules : Hash(String, CodeGenVisitor::ModuleInfo), objects : Hash(String, String),
                         output_dir : String, output_filename : String, & : String, Float64 ->) : Array(CompilationUnit)
      started = Time.instant
      units = modules.map do |name, info|
        info.mod.target = target_machine.triple
        CompilationUnit.new(self, program, name, info.mod, output_dir, false)
      end
      names = objects.dup
      with_file_lock(output_dir) do
        units.each do |unit|
          unit.compile
          names[unit.original_name == "_main" ? "" : unit.original_name] = unit.object_filename
        end
        yield "Codegen (bc+obj)", (Time.instant - started).total_seconds
        started = Time.instant
        Dir.cd(output_dir) do
          run_linker *linker_command(program, names.values, File.expand_path(output_filename), output_dir, expand: true)
        end
        yield "Codegen (linking)", (Time.instant - started).total_seconds
      end
      objects.merge!(names)
      units
    end
  end
end
