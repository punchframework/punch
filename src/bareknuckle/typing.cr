module Bareknuckle
  # Types the app as `punch dev` builds it (same main file and flags), with
  # the semantic pass only, and maps the result (`ProgramMap`).
  #
  # The daemon types in a worker process (`apart`): a process that types
  # the same program again keeps most of its heap (1.3 GB after one typing
  # of the reference app, 2.6 GB after four), while a worker gives all of
  # it back when it exits.
  class Typing
    # *type_ids* is a digest of the type IDs codegen assigns
    # (`Crystal::LLVMId`).
    record Result, map : ProgramMap, files : Hash(String, String), macro_files : Set(String),
      macro_commands : Set(String), type_ids : String, seconds : Float64, walk_seconds : Float64 do
      include JSON::Serializable
    end

    @worker : Process? = nil

    def initialize(@main : String, @flags : Array(String))
    end

    # Stops the running worker while a build runs (SIGSTOP), so the two
    # never compete; `resume` lets it go on.
    def pause : Nil
      @worker.try { |worker| worker.signal(Signal::STOP) rescue nil }
    end

    def resume : Nil
      @worker.try { |worker| worker.signal(Signal::CONT) rescue nil }
    end

    # `run` in a worker process (`bareknuckle type`, the same binary).
    # Raises `Crystal::Error` when it does not type.
    def apart(overlay : Hash(String, String)) : Result
      output = IO::Memory.new
      error = IO::Memory.new
      worker = Process.new(Process.executable_path || raise(Crystal::Error.new("no executable path")),
        ["type", "--main", @main] + @flags.flat_map { |flag| ["-D", flag] },
        input: IO::Memory.new(overlay.to_json), output: output, error: error)
      @worker = worker
      status = worker.wait
      @worker = nil
      raise Crystal::Error.new(error.to_s.lines.first? || "the typing worker failed (#{status})") unless status.success?

      Result.from_json(output.to_s)
    end

    # Types the program with *overlay* in place of the app's files on disk
    # (`Sources`). Raises `Crystal::CodeError` when it does not type.
    def run(overlay : Hash(String, String)) : Result
      Sources.overlay = overlay
      Sources.read.clear
      MacroReads.clear
      started = Time.instant
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      compiler.color = false
      # The build prints the warnings and the macros' output already.
      compiler.warnings.level = :none
      compiler.stdout = IO::Memory.new
      compiler.stderr = IO::Memory.new
      @flags.each { |flag| compiler.flags << flag }
      result = compiler.compile(Crystal::Compiler::Source.new(@main, Sources.read(@main)), "bareknuckle")
      typed = Time.instant
      map = ProgramMap.build(result, Sources.root)
      Result.new(map, Sources.read.dup, MacroReads.files.dup, MacroReads.commands.dup, Crystal::LLVMId.new(result.program).digest,
        (typed - started).total_seconds, (Time.instant - typed).total_seconds)
    end
  end
end
