require "../../bareknuckle"

module Punch::CLI::Commands
  # `punch bareknuckle:build`: builds the bareknuckle daemon
  # from Punch's sources into `bin/bareknuckle` beside them (the app's
  # `lib/punch/bin/bareknuckle`), with the Crystal the app builds with. Once
  # it is built, `punch dev` builds the app with it.
  #
  # It compiles Crystal's compiler from the sources every Crystal install
  # ships, so it needs LLVM's development files (`llvm-config`), which a
  # Crystal install does not include. Optimized (`OPTIMIZATION`), not
  # `--release`: optimizing the compiler as one module needs about 5 GB.
  class BareknuckleBuild < Command
    command "bareknuckle:build", "Build the bareknuckle daemon, the incremental compiler punch dev builds with (needs LLVM's development files)"

    OPTIMIZATION = "-O2"

    struct Result
      include Report

      def initialize(@binary : String, @crystal : String, @seconds : Float64)
      end

      def to_text(io : IO) : Nil
        io.puts "Built #{@binary} for Crystal #{@crystal} (#{@seconds.round} s). punch dev --bareknuckle (or PUNCH_BAREKNUCKLE=on) builds with it."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "binary", @binary
          json.field "crystal", @crystal
          json.field "seconds", @seconds.round(1)
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end
      return Failure.new("no_sources", "#{Bareknuckle::Daemon::SOURCE} does not exist: this punch was built without its sources.") unless File.exists?(Bareknuckle::Daemon::SOURCE)
      unless Process.find_executable(ENV["LLVM_CONFIG"]? || "llvm-config")
        return Failure.new("no_llvm", "llvm-config was not found: building bareknuckle links Crystal's compiler, which needs LLVM's development files (llvm-config on the PATH, or LLVM_CONFIG).")
      end

      started = Time.instant
      Dir.mkdir_p(File.dirname(Bareknuckle::Daemon::BINARY))
      output = IO::Memory.new
      status = Process.run("crystal", ["build", Bareknuckle::Daemon::SOURCE, "-o", Bareknuckle::Daemon::BINARY, OPTIMIZATION,
                                       "-Dwithout_interpreter", "-Dwithout_playground", "--no-color"], output: output, error: output)
      return Failure.new("build_failed", "Building #{Bareknuckle::Daemon::SOURCE} failed:\n#{output}") unless status.success?

      Result.new(Bareknuckle::Daemon::BINARY, Bareknuckle::Daemon.crystal("CRYSTAL_VERSION"), (Time.instant - started).total_seconds)
    end
  end
end
