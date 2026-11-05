require "./project"
require "../../requires_gen"

module Punch::CLI::Commands
  # Writes `app/requires.gen.cr`: every Crystal file under `app/`, required
  # in the order of its kind (`lib/punch/docs/structure.md`). The app's
  # library file requires only Punch and this file. With `--check`, writes
  # nothing and fails when the file is stale.
  class RequiresGenerate < Command
    command "requires:generate", "Generate app/requires.gen.cr, requiring every file under app/ in the order of its kind; --check compares instead"

    struct Result
      include Report

      def initialize(@state : String, @path : String, @files : Int32)
      end

      def to_text(io : IO) : Nil
        io.puts "#{@state.ljust(9)} #{@path} (#{@files} files)"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", @path
          json.field "state", @state
          json.field "files", @files
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      check = args.delete("--check")
      if extra = args.first?
        return Failure.usage("unexpected_argument", "'punch requires:generate' takes --check, not '#{extra}'.")
      end
      return Failure.new("no_app", "There is no app/ directory to require.") unless RequiresGenerate.applies?

      output = RequiresGen.run
      path = RequiresGen::OUTPUT
      current = File.exists?(path) ? File.read(path) : nil
      if check
        return Result.new("current", path, output.files) if current == output.content

        return Failure.new("stale_generated_files", "#{path} does not match the files under app/. Run 'punch requires:generate' and commit the result; never edit it by hand.")
      end
      return Result.new("unchanged", path, output.files) if current == output.content

      File.write(path, output.content)
      Result.new("written", path, output.files)
    rescue ex : QueryGen::Errors
      Failure.new("generate_failed", "#{ex.message}\n#{RequiresGen.kinds}")
    end

    # Whether the tools run this: an app with an `app/` directory.
    def self.applies? : Bool
      Dir.exists?(RequiresGen::DIRECTORY)
    end
  end
end
