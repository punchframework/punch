require "json"
require "levenshtein"
require "./cli/report"
require "./cli/command"
require "./cli/commands/*"

module Punch
  # The `punch` command line.
  #
  # Conventions, shared by every command:
  # - `--json` anywhere in the arguments makes stdout carry exactly one JSON
  #   document, for success and failure alike. Nothing else is written to it.
  # - Without `--json`, results go to stdout as text and failures to stderr.
  # - Exit codes: 0 success, 1 the command failed, 2 usage error.
  # - An exception is a bug: it is reported as `internal_error` with exit code
  #   1, and its backtrace goes to stderr.
  module CLI
    COMMANDS = [Commands::Help, Commands::Version, Commands::Config, Commands::Db, Commands::DbShell,
                Commands::DbMigration, Commands::DbMigrate, Commands::DbStatus, Commands::DbSchema,
                Commands::CredsInit, Commands::CredsEdit, Commands::CredsShow, Commands::CredsSet, Commands::CredsUnset,
                Commands::CredsRekey, Commands::KeysList, Commands::KeysRotate, Commands::KeysPromote,
                Commands::KeysRetire, Commands::KeysPublicID, Commands::CacheStats, Commands::CacheClear, Commands::BansList, Commands::BansLift, Commands::JobsList, Commands::JobsShow,
                Commands::JobsStats, Commands::JobsRetry, Commands::JobsDiscard, Commands::JobsPause,
                Commands::JobsResume, Commands::OpsOverview, Commands::OpsErrors, Commands::OpsError, Commands::OpsResolve, Commands::OpsReopen,
                Commands::OpsJobs, Commands::OpsJob, Commands::OpsRetry, Commands::OpsDiscard, Commands::OpsPerformance,
                Commands::OpsSlow, Commands::OpsRecord, Commands::Backup, Commands::BackupConfig, Commands::BackupVerify,
                Commands::Restore, Commands::Recovery, Commands::RecoveryConfirm] of Command.class

    # The commands of an application binary, which knows its operations
    # and its settings (the token prefix):
    # `exit Punch::CLI.run(ARGV, commands: Punch::CLI::APP_COMMANDS)`.
    APP_COMMANDS = COMMANDS + [Commands::DbAudit, Commands::DbEncrypt, Commands::DbUpgrade, Commands::Routes, Commands::Events, Commands::Webhooks, Commands::JobsTypes, Commands::JobsVersions, Commands::JobsRun, Commands::Assets, Commands::Serve, Commands::CredsCheck, Commands::SessionsList,
                               Commands::SessionsRevoke, Commands::TokensList, Commands::TokensCreate,
                               Commands::TokensRevoke, Commands::PasswordsReport, Commands::IdentitiesList,
                               Commands::RateLimitsList, Commands::RateLimitsReset, Commands::RolesList, Commands::RolesAssign, Commands::RolesRevoke] of Command.class
    {% if flag?(:punch_openapi) %}
      APP_COMMANDS << Commands::OpenAPIDerive << Commands::JobsDerive << Commands::AuthzExplain
    {% end %}

    # What a binary does with a command it does not have: the exit code of
    # whatever ran instead (it wrote to the IOs given), a failure, or nil when
    # it does not apply either. The standalone `punch` forwards to the app's
    # binary (`Forward`).
    alias Fallback = Proc(Array(String), IO, IO, (Int32 | Failure)?)

    @@program = "punch"

    # The name this binary goes by in its help and messages: `punch`, or the
    # application binary's own name.
    def self.program : String
      @@program
    end

    # Runs the command line *argv* and returns the exit code. An application
    # binary (one with `serve`) names itself by its file name in its usage;
    # *program* sets the name.
    def self.run(argv : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR,
                 commands : Array(Command.class) = COMMANDS, fallback : Fallback? = nil,
                 program : String? = nil) : Int32
      json = argv.includes?("--json")
      args = argv.reject("--json")
      @@program = program || (commands.includes?(Commands::Serve) ? File.basename(PROGRAM_NAME) : "punch")

      outcome = begin
        forwarded = fallback.try { |forward| forward_unknown(argv, args, commands, forward, stdout, stderr) }
        return forwarded if forwarded.is_a?(Int32)

        forwarded || dispatch(args, commands, json)
      rescue ex
        stderr.puts ex.inspect_with_backtrace
        Failure.new("internal_error", "Internal error: #{ex.message}")
      end

      emit(outcome, json, stdout, stderr)
    end

    private def self.forward_unknown(argv : Array(String), args : Array(String), commands : Array(Command.class),
                                     forward : Fallback, stdout : IO, stderr : IO) : (Int32 | Failure)?
      name = args.first?
      return if name.nil? || name.starts_with?('-') || commands.any?(&.command_name.==(name))

      forward.call(argv, stdout, stderr)
    end

    private def self.dispatch(args : Array(String), commands : Array(Command.class), json : Bool) : Report | Failure
      case name = args.shift?
      when nil, "--help", "-h" then Commands::Help.new(commands).run(args)
      when "--version"         then Commands::Version.new(commands).run(args)
      else
        if command = commands.find(&.command_name.==(name))
          if json && !command.json?
            return Failure.usage("no_json_mode", "'punch #{name}' is interactive and has no JSON mode.")
          end

          instance = command.new(commands)
          instance.json_output = json
          instance.run(args)
        else
          unknown(name, commands)
        end
      end
    end

    # The usage error for *name*, with the commands it may have meant: any
    # command of either binary (`APP_COMMANDS` and *commands*).
    private def self.unknown(name : String, commands : Array(Command.class)) : Failure
      names = (commands + APP_COMMANDS).map(&.command_name).uniq!
      tolerance = {name.size // 3, 2}.max
      distances = names.map { |candidate| {candidate, Levenshtein.distance(name, candidate)} }.select { |_, distance| distance <= tolerance }
      nearest = distances.min_of?(&.[1])
      guesses = distances.select { |_, distance| distance == nearest }.map(&.[0]).first(3)
      return Failure.usage("unknown_command", "Unknown command '#{name}'. Run '#{program} help' for a list.") if guesses.empty?

      hint = guesses.join(" or ") { |guess| "'#{guess}'" }
      Failure.new("unknown_command", "Unknown command '#{name}'. Did you mean #{hint}? Run '#{program} help' for a list.",
        Failure::USAGE_EXIT_CODE, JSON.parse({"did_you_mean" => guesses}.to_json))
    end

    private def self.emit(outcome : Report | Failure, json : Bool, stdout : IO, stderr : IO) : Int32
      case outcome
      in Report
        json ? (outcome.to_json(stdout); stdout.puts) : outcome.to_text(stdout)
        0
      in Failure
        json ? (outcome.to_json(stdout); stdout.puts) : stderr.puts("#{program}: #{outcome.message}")
        outcome.exit_code
      end
    end
  end
end
