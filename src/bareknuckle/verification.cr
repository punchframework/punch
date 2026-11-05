module Bareknuckle
  # Compares the object cache `punch dev` linked its app from with the cache
  # of a full build of the same files: the verification build `punch dev`
  # runs when idle.
  #
  # A module whose bitcode is the same byte for byte matches. Otherwise
  # both are read and compared function by function, ignoring what a
  # round on the fast path changes without changing the program: the
  # order of functions (codegen adds them as it first reaches them), the
  # numbers of temporaries and macro expansions (numbered program-wide),
  # the numbering of metadata and attribute groups, and the suffixes LLVM
  # adds to string constants whose names collide, and of the structs
  # closures keep their variables in. Each instruction's line
  # and column are compared, since `punch dev` builds keep debug
  # information.
  module Verification
    # What differs, one line per module and function; empty when nothing.
    def self.compare(mine : String, theirs : String) : Array(String)
      mismatches = [] of String
      Dir.glob("#{theirs}/*.bc").sort!.each do |path|
        name = File.basename(path)
        own = File.join(mine, name)
        next if File.basename(name, ".bc").ends_with?(".new")
        unless File.exists?(own)
          mismatches << "#{name}: not in punch dev's cache"
          next
        end
        next if File.same_content?(own, path)

        a = summary(own, File.dirname(mine))
        b = summary(path, File.dirname(theirs))
        next if a == b

        names = (a.keys + b.keys).uniq!.select { |key| a[key]? != b[key]? }.sort!
        if dump = ENV["BAREKNUCKLE_VERIFY_DUMP"]?
          Dir.mkdir_p(dump)
          names.each_with_index do |key, index|
            File.write("#{dump}/#{name}.#{index}.mine", a[key]? || "")
            File.write("#{dump}/#{name}.#{index}.theirs", b[key]? || "")
          end
        end
        mismatches << "#{name}: #{names.first(3).join(", ")}#{names.size > 3 ? " and #{names.size - 3} more" : ""}"
      end
      mismatches
    end

    TEMPORARY  = /__temp_(?:[0-9a-f]{8}_)?\d+/
    MACRO      = /macro_\d+/
    METADATA   = /,? !dbg !\d+|![0-9]+/
    ATTRIBUTES = /#\d+/
    STRING     = /"('[^"]*')\.\d+"/
    CLOSURE    = /%closure_\d+/

    # Each defined function's code and lines, and the module's globals,
    # normalized. The program holds the cache directory it was built with
    # (`Crystal::CACHE_DIR`), *cache*, which differs between the builds.
    def self.summary(path : String, cache : String) : Hash(String, String)
      context = LLVM::Context.new
      mod = LLVM::Module.parse(LLVM::MemoryBuffer.from_file(path), context)
      summary = {} of String => String
      mod.functions.each do |function|
        next unless LibLLVM.is_declaration(function) == 0

        lines = String.build do |io|
          function.basic_blocks.each do |block|
            instruction = LibLLVM.get_first_instruction(block)
            until instruction.null?
              io << LibLLVM.get_debug_loc_line(instruction) << ':' << LibLLVM.get_debug_loc_column(instruction) << ' '
              instruction = LibLLVM.get_next_instruction(instruction)
            end
          end
        end
        summary[function.name] = "#{normalize(String.new(LibLLVM.print_value_to_string(function)))}\n#{lines}"
      end
      globals = [] of String
      global = LibLLVM.get_first_global(mod)
      until global.null?
        text = String.new(LibLLVM.print_value_to_string(global))
        globals << (text.includes?(cache) ? "(the cache directory)" : normalize(text))
        global = LibLLVM.get_next_global(global)
      end
      summary["(globals)"] = globals.sort!.join('\n')
      summary
    end

    def self.normalize(text : String) : String
      text.gsub(TEMPORARY, "__temp").gsub(MACRO, "macro_").gsub(METADATA, "").gsub(ATTRIBUTES, "#").gsub(STRING, "\"\\1\"").gsub(CLOSURE, "%closure")
    end
  end
end
