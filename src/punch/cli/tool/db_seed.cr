module Punch::CLI
  module Commands
    # Builds and runs the app's `db/seeds.cr` against the development
    # database (`Punch::Seeds`, docs/tooling.md). The seed refuses outside
    # development itself; this refuses earlier, before the build.
    class DbSeed < Command
      command "db:seed", "Fill the development database from db/seeds.cr, through the app's own Commands"

      SEEDS  = "db/seeds.cr"
      BINARY = "tmp/punch-seeds/seeds"

      struct Result
        include Report

        def initialize(@output : String)
        end

        def to_text(io : IO) : Nil
          io << @output
        end

        def to_json(json : JSON::Builder) : Nil
          json.object { json.field "output", @output }
        end
      end

      def run(args : Array(String)) : Report | Failure
        if failure = no_arguments(args)
          return failure
        end

        environment = ENV["PUNCH_ENV"]?.presence || "development"
        unless environment == "development"
          return Failure.new("not_development", "Seeds are for development; PUNCH_ENV is #{environment}.")
        end
        return Failure.new("no_seeds", "#{SEEDS} does not exist; it holds the development data (lib/punch/docs/tooling.md).") unless File.exists?(SEEDS)

        build = Project.build(SEEDS, BINARY)
        return Failure.new("build_failed", "Building #{SEEDS} failed:\n#{build.output}") unless build.success

        output = IO::Memory.new
        status = Process.run(BINARY, output: output, error: output)
        return Failure.new("seed_failed", output.to_s.strip) unless status.success?

        Result.new(output.to_s)
      end
    end
  end
end
