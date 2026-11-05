module Punch::CLI::Commands
  # Shows how the database files are backed up: the replica, the files
  # replicated, exempted, or lacking a replica, whether a Litestream
  # answers on the control socket, each file's lag, and the bucket's
  # encryption, asked now (`docs/backup.md`).
  class Backup < Command
    command "backup", "Show the backup: replica, Litestream, lag per file, bucket encryption (see PUNCH_BACKUP_URL)"

    struct Result
      include Report

      def initialize(@config : Punch::Backup::Config, @litestream : Punch::Backup::Litestream,
                     @missing : Array(String), @required : Bool, @info : Punch::Backup::Litestream::Info?,
                     @replicas : Array(Punch::Backup::Litestream::Replica)?, @lags : Hash(String, Time::Span?),
                     @encryption : Punch::Backup::Encryption::Result, @verification : Punch::Backup::VerificationStatus?,
                     @recovery : Punch::Backup::Recovery::Report?)
      end

      def to_text(io : IO) : Nil
        io.puts "replica     #{@config.display_url || "none (PUNCH_BACKUP_URL unset)"}"
        io.puts "replicated  #{@litestream.names.empty? ? "nothing" : @litestream.names.join(", ") { |name| "#{name}.db" }}"
        @recovery.try { |report| io.puts "recovery    since #{report.restored_at.to_rfc3339}: background work waits for punch recovery:confirm" }
        io.puts "exempt      #{@config.exempt.join(", ") { |name| "#{name}.db" }}" unless @config.exempt.empty?
        unless @missing.empty?
          io.puts "missing     #{@missing.join(", ") { |name| "#{name}.db" }}#{@required ? " (fails the health check)" : " (allowed in development and test)"}"
        end
        return if @litestream.names.empty?

        if info = @info
          io.puts "litestream  #{info.version}, process #{info.pid}, up #{info.uptime.total_seconds.to_i} s (#{@litestream.socket_path})"
        else
          io.puts "litestream  not answering on #{@litestream.socket_path}"
        end
        @litestream.names.each do |name|
          replica = @replicas.try(&.find { |entry| entry.path == @litestream.database_path(name) })
          lag = @lags[name]?
          synced = replica.try(&.last_sync_at).try { |time| "last upload #{time.to_rfc3339}" } || "no upload seen"
          io.puts "  #{name.ljust(8)} #{replica.try(&.status) || "unknown"}, lag #{lag ? "#{lag.total_seconds.round(1)} s" : "unknown"}, #{synced}"
        end
        io.puts "encryption  #{Backup.describe(@encryption)}"
        io.puts "verified    #{Backup.describe(@verification)}"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "url", @config.display_url
          json.field "replicated", @litestream.names
          json.field "exempt", @config.exempt
          json.field "missing", @missing
          json.field "missing_fails_health", @required
          json.field "litestream" do
            if info = @info
              json.object do
                json.field "version", info.version
                json.field "pid", info.pid
                json.field "uptime_seconds", info.uptime.total_seconds.to_i64
              end
            else
              json.null
            end
          end
          json.field "files" do
            json.array do
              @litestream.names.each do |name|
                replica = @replicas.try(&.find { |entry| entry.path == @litestream.database_path(name) })
                json.object do
                  json.field "name", name
                  json.field "path", @litestream.database_path(name)
                  json.field "replica_url", @config.replica_url(name)
                  json.field "status", replica.try(&.status)
                  json.field "last_sync_at", replica.try(&.last_sync_at).try(&.to_rfc3339)
                  json.field "lag_seconds", @lags[name]?.try(&.total_seconds)
                end
              end
            end
          end
          json.field "verification", @verification
          json.field "recovering_since", @recovery.try(&.restored_at.to_rfc3339)
          json.field "encryption" do
            json.object do
              case result = @encryption
              in Punch::Backup::Encryption::Encrypted
                json.field "state", "encrypted"
                json.field "algorithm", result.algorithm
              in Punch::Backup::Encryption::Unencrypted
                json.field "state", "unencrypted"
              in Punch::Backup::Encryption::Unknown
                json.field "state", "unknown"
                json.field "reason", result.reason
              in Punch::Backup::Encryption::NotChecked
                json.field "state", "not_checked"
                json.field "reason", result.reason
              end
            end
          end
        end
      end
    end

    def self.describe(result : Punch::Backup::Encryption::Result) : String
      case result
      in Punch::Backup::Encryption::Encrypted   then "the bucket encrypts by default (#{result.algorithm})"
      in Punch::Backup::Encryption::Unencrypted then "NOT ENCRYPTED: the bucket has no default encryption (fails the health check)"
      in Punch::Backup::Encryption::Unknown     then "unknown: #{result.reason} (fails the health check)"
      in Punch::Backup::Encryption::NotChecked  then "not checked: #{result.reason}"
      end
    end

    # The last restore check, for people.
    def self.describe(status : Punch::Backup::VerificationStatus?) : String
      return "never: the restore check runs every night at 04:00 UTC (punch backup:verify runs it now)" unless status

      result = status.passed? ? "passed" : "FAILED (#{status.problems.first?})"
      since = status.passed? ? "" : status.last_passed_at.try { |time| ", last passed #{time.to_rfc3339}" } || ", never passed"
      found = status.reconciliation.try { |counts| counts.reject { |_, count| count.zero? } }
      dry_run = found.nil? ? "" : found.empty? ? "; reconciliation: nothing to do" : "; reconciliation: #{found.join(", ") { |key, count| "#{count} #{key}" }}"
      "#{status.finished_at.to_rfc3339}: #{result}#{since}#{dry_run}"
    end

    def self.litestream(settings : Punch::AppConfig) : Punch::Backup::Litestream
      names = Punch::Backup::Config::FILES.reject { |name| name == "ops" && !settings.ops? }
      Punch::Backup::Litestream.new(settings.backup, settings.storage, names)
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      settings = Config.settings
      return settings if settings.is_a?(Failure)

      names = Punch::Backup::Config::FILES.reject { |name| name == "ops" && !settings.ops? }
      litestream = Backup.litestream(settings)
      monitor = Punch::Backup::Monitor.new(litestream, names, settings.environment)
      replicas = litestream.names.empty? ? nil : litestream.replicas
      now = Time.utc
      lags = litestream.names.to_h do |name|
        path = litestream.database_path(name)
        synced = replicas.try(&.find { |replica| replica.path == path }).try(&.last_sync_at)
        # Without an answer from Litestream, the lag is unknown here.
        {name, synced ? Punch::Backup::Monitor.lag(Punch::Backup::Monitor.changed_at(path), synced, synced, now) : nil}
      end
      Result.new(settings.backup, litestream, monitor.missing, monitor.required?, replicas ? litestream.info : nil,
        replicas, lags, Punch::Backup::Encryption.check(settings.backup),
        litestream.names.empty? ? nil : Punch::Backup::VerificationStatus.read(litestream.storage),
        Punch::Backup::Recovery.read(settings.storage))
    end
  end

  # Prints the Litestream configuration `serve` and `jobs` write at every
  # start, for running Litestream another way or reading what it does.
  class BackupConfig < Command
    command "backup:config", "Print the Litestream configuration Punch generates from PUNCH_BACKUP_URL"

    struct Result
      include Report

      def initialize(@path : String, @yaml : String)
      end

      def to_text(io : IO) : Nil
        io.print @yaml
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", @path
          json.field "yaml", @yaml
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      settings = Config.settings
      return settings if settings.is_a?(Failure)

      litestream = Backup.litestream(settings)
      if litestream.names.empty?
        return Failure.new("no_backup", "Nothing is replicated: set PUNCH_BACKUP_URL (and PUNCH_BACKUP_EXEMPT leaves #{settings.backup.exempt.join(", ")} out).")
      end

      Result.new(litestream.configuration_path, litestream.yaml)
    end
  end

  # Runs the restore check now, as the nightly `Punch::Backup::Verify`
  # does: restores every replicated file next to the live ones, checks its
  # integrity, and runs the reconciliation as a dry run
  # (`docs/backup.md`). Fails when the check does.
  class BackupVerify < Command
    command "backup:verify", "Restore the backup into a scratch directory, check it, and dry-run the reconciliation"

    struct Result
      include Report

      def initialize(@verification : Punch::Backup::Verification)
      end

      def to_text(io : IO) : Nil
        aligned = @verification.aligned_at.try { |time| ", every file restored to #{time.to_rfc3339} (a replica is behind)" }
        io.puts "restore check passed#{aligned}"
        @verification.messages.each { |line| io.puts "  #{line}" }
      end

      def to_json(json : JSON::Builder) : Nil
        @verification.to_json(json)
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      settings = Config.settings
      return settings if settings.is_a?(Failure)

      litestream = Backup.litestream(settings)
      if litestream.names.empty?
        return Failure.new("no_backup", "Nothing is replicated: set PUNCH_BACKUP_URL.")
      end
      if problem = litestream.problem
        return Failure.new("backup_unavailable", problem)
      end
      return Failure.new("no_storage", "#{litestream.storage} does not exist.") unless Dir.exists?(litestream.storage)

      verification = Punch::Backup::Verification.run(litestream, settings.job_retention)
      return Result.new(verification) if verification.passed?

      Failure.new("restore_check_failed", "The restore check failed:\n  #{verification.messages.join("\n  ")}",
        details: JSON.parse(verification.to_json))
    end
  end
end
