require "./project"
require "./routes"

module Punch::CLI
  # A command the standalone `punch` does not have but an application's
  # binary does (`jobs:versions`, `db:audit`, `tokens:create`, ...): `punch`
  # builds the app the way `punch routes` does and runs its binary with the
  # same arguments, so one entry point serves both command sets. The binary's
  # stdout, stderr and exit code are the command's.
  module Forward
    BINARY = Commands::ToolRoutes::BINARY

    # Whether the application binary is where *name* belongs: some command of
    # `APP_COMMANDS` the tool has no command of its own for.
    def self.app_command?(name : String) : Bool
      APP_COMMANDS.any?(&.command_name.==(name))
    end

    # What `CLI.run` calls for a command it does not know.
    FALLBACK = ->(argv : Array(String), stdout : IO, stderr : IO) { run(argv, stdout, stderr) }

    # Runs *argv* (with `--json` where given) in the app's binary and returns
    # its exit code, nil for a command no application binary has, or the failure that kept it from running: not an app, or
    # a build that failed. An app whose binary does not know the command
    # answers as the tool does for any unknown command.
    def self.run(argv : Array(String), stdout : IO, stderr : IO) : (Int32 | Failure)?
      name = argv.reject("--json").first
      return unless app_command?(name)

      project = Project.load
      if project.is_a?(Failure)
        return Failure.new("no_app", "'#{name}' is a command of your application's binary, which 'punch' builds and runs for you from the app's root (the directory with shard.yml). #{project.message}")
      end
      unless project.punch_app?
        return Failure.usage("unknown_command", "Unknown command '#{name}'. #{project.name} does not depend on Punch, so it has no application commands.")
      end

      build = Project.build(project.main, BINARY)
      return Failure.new("build_failed", "Building #{project.main} failed:\n#{build.output}") unless build.success
      unless defines?(name)
        return Failure.usage("unknown_command", "Unknown command '#{name}': #{project.name}'s binary does not define it either. Run '#{CLI.program} help' for a list.")
      end

      status = Process.run(BINARY, argv, input: Process::Redirect::Inherit, output: stdout, error: stderr)
      status.exit_code
    end

    # Whether the built binary lists *name* among its commands.
    private def self.defines?(name : String) : Bool
      output = IO::Memory.new
      status = Process.run(BINARY, ["help", "--json"], output: output, error: Process::Redirect::Close)
      return true unless status.success?

      JSON.parse(output.to_s)["commands"].as_a.any?(&.["name"].as_s.==(name))
    rescue JSON::ParseException | KeyError
      true
    end
  end
end
