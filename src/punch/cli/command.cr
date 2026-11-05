module Punch::CLI
  # A `punch` subcommand. Subclasses declare their name and summary with
  # `command` and implement `run`. Add new commands to `CLI::COMMANDS`.
  abstract class Command
    macro command(name, summary)
      def self.command_name : String
        {{ name }}
      end

      def self.summary : String
        {{ summary }}
      end
    end

    # Whether the command has a JSON mode. Only an interactive command, which
    # hands the terminal to another program, may say no; with `--json` it
    # then fails with the usage error `no_json_mode`.
    def self.json? : Bool
      true
    end

    # All commands of this command line, for `help`.
    getter commands : Array(Command.class)

    # Whether `--json` was given: stdout then carries only the document.
    property? json_output : Bool = false

    def initialize(@commands : Array(Command.class))
    end

    # *args* are the arguments after the command name, without `--json`.
    abstract def run(args : Array(String)) : Report | Failure

    # Rejects arguments for commands that take none.
    protected def no_arguments(args : Array(String)) : Failure?
      return if args.empty?

      Failure.usage("unexpected_argument", "'punch #{self.class.command_name}' takes no arguments, got '#{args.first}'.")
    end
  end
end
