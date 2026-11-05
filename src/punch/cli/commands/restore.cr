module Punch::CLI::Commands
  # Restores every replicated file from its replica into the storage
  # directory, while the app is stopped, and puts the app into recovery
  # mode: background work waits until the reconciliation is confirmed
  # (`punch recovery:confirm`). The files it replaces are moved aside
  # (`docs/backup.md`, "Restoring").
  class Restore < Command
    command "restore", "Restore the backup into PUNCH_STORAGE (app stopped) and start recovery mode: punch restore [--at TIME] [--dry-run]"

    USAGE = "Usage: punch restore [--at TIME] [--dry-run] (TIME in RFC 3339, such as 2026-10-14T09:30:00Z)"

    struct Restored
      include Report

      def initialize(@report : Punch::Backup::Recovery::Report)
      end

      def to_text(io : IO) : Nil
        io.puts "restored #{Restore.describe(@report.files, @report.aligned_at, @report.requested)}"
        @report.messages.each { |line| io.puts "  #{line}" }
        io.puts "recovery mode: requests are served; job workers, the outbox relay, and recurring schedules wait."
        io.puts "Check the lists with `punch recovery`, then confirm with `punch recovery:confirm`."
      end

      def to_json(json : JSON::Builder) : Nil
        @report.to_json(json)
      end
    end

    struct Planned
      include Report

      def initialize(@aligned_at : Time?, @plans : Array(Punch::Backup::Restorer::Plan), @requested : Time?)
      end

      def to_text(io : IO) : Nil
        io.puts "would restore #{Restore.describe(@plans, @aligned_at, @requested)} (dry run, nothing downloaded)"
        @plans.each do |plan|
          io.puts "  #{plan.name}.db: transaction #{plan.max_txid.lstrip('0')} of #{plan.point.to_rfc3339}, #{plan.files} replica files, #{plan.bytes} bytes"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "dry_run", true
          json.field "requested", @requested.try(&.to_rfc3339)
          json.field "aligned_at", @aligned_at.try(&.to_rfc3339)
          json.field "files", @plans
        end
      end
    end

    # Which point the files go to, for people.
    def self.describe(plans : Array(Punch::Backup::Restorer::Plan), aligned_at : Time?, requested : Time?) : String
      files = plans.join(", ") { |plan| "#{plan.name}.db" }
      if aligned_at
        "#{files}, every file to #{aligned_at.to_rfc3339} (a replica ends there)"
      elsif requested
        "#{files}, each to its last point at #{requested.to_rfc3339} or before"
      else
        "#{files}, each to its latest point"
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      dry_run = !!args.delete("--dry-run")
      at = JobsCommand.option(args, "--at")
      return at if at.is_a?(Failure)
      return Failure.usage("unexpected_argument", USAGE) unless args.empty?

      requested = begin
        at.try { |text| Time::Format::RFC_3339.parse(text) }
      rescue Time::Format::Error
        return Failure.usage("invalid_time", "--at takes a time in RFC 3339, such as 2026-10-14T09:30:00Z: #{at.inspect}")
      end
      settings = Config.settings
      return settings if settings.is_a?(Failure)

      litestream = Backup.litestream(settings)
      return Failure.new("no_backup", "Nothing is replicated: set PUNCH_BACKUP_URL to the replica to restore from.") if litestream.names.empty?
      if problem = litestream.problem
        return Failure.new("backup_unavailable", problem)
      end

      if dry_run
        planned = Punch::Backup::Recovery.plan(litestream, at: requested)
        return Restore.failure(planned) if planned.is_a?(Punch::Backup::Recovery::Refused)

        return Planned.new(planned[0], planned[1], requested)
      end

      case result = Punch::Backup::Recovery.restore(litestream, settings.job_retention, at: requested)
      in Punch::Backup::Recovery::Report  then Restored.new(result)
      in Punch::Backup::Recovery::Refused then Restore.failure(result)
      end
    end

    def self.failure(refused : Punch::Backup::Recovery::Refused) : Failure
      message = refused.problems.empty? ? refused.message : "#{refused.message}\n  #{refused.problems.join("\n  ")}"
      Failure.new(refused.code, message, details: refused.problems.empty? ? nil : JSON.parse({problems: refused.problems}.to_json))
    end
  end

  # Shows the restore waiting for confirmation: the files and points
  # restored, and the reconciliation's lists. Without one, the last
  # confirmed recovery.
  class Recovery < Command
    command "recovery", "Show the restore waiting for confirmation and its reconciliation (see punch restore)"

    struct Result
      include Report

      def initialize(@pending : Punch::Backup::Recovery::Report?, @last : Punch::Backup::Recovery::Report?)
      end

      def to_text(io : IO) : Nil
        if report = @pending
          io.puts "recovery mode since #{report.restored_at.to_rfc3339}: background work waits for `punch recovery:confirm`"
          io.puts "restored #{Restore.describe(report.files, report.aligned_at, report.requested)}"
          report.messages.each { |line| io.puts "  #{line}" }
          Recovery.proposals(report).each { |line| io.puts line }
        else
          io.puts "not in recovery mode"
          @last.try { |last| io.puts "last recovery: restored #{last.restored_at.to_rfc3339}, confirmed #{last.confirmed_at.try(&.to_rfc3339)}" }
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "recovering", !@pending.nil?
          json.field "pending", @pending
          json.field "last", @last
        end
      end
    end

    # What confirming does, for people.
    def self.proposals(report : Punch::Backup::Recovery::Report) : Array(String)
      found = report.reconciliation || return ["Confirming starts background work."]
      ["Confirming hands #{found.reenqueue.size} outbox entries over again, discards #{found.discard.size} jobs, " \
       "runs #{found.rerun.size} finished jobs again, makes #{found.interrupted.size} interrupted jobs ready, " \
       "and starts background work. #{found.orphaned.size} jobs ran for Commands not in the primary: review what they did."]
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      settings = Config.settings
      return settings if settings.is_a?(Failure)

      Result.new(Punch::Backup::Recovery.read(settings.storage), Punch::Backup::Recovery.last(settings.storage))
    end
  end

  # Confirms the restore waiting in recovery mode: applies the
  # reconciliation and starts background work in every running process.
  class RecoveryConfirm < Command
    command "recovery:confirm", "Apply the reconciliation after punch restore and start background work again"

    struct Result
      include Report

      def initialize(@report : Punch::Backup::Recovery::Report)
      end

      def to_text(io : IO) : Nil
        applied = @report.applied || {} of String => Int64
        if applied.empty?
          io.puts "recovery confirmed: nothing to reconcile"
        else
          io.puts "recovery confirmed: #{applied["reenqueue"]? || 0} outbox entries to hand over again, #{applied["discard"]? || 0} jobs discarded, " \
                  "#{applied["rerun"]? || 0} to run again, #{applied["interrupted"]? || 0} interrupted made ready"
        end
        io.puts "Running processes start background work within #{Punch::Backup::Recovery::Hold::POLL.total_seconds.to_i} s."
      end

      def to_json(json : JSON::Builder) : Nil
        @report.to_json(json)
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      settings = Config.settings
      return settings if settings.is_a?(Failure)

      case result = Punch::Backup::Recovery.confirm(settings.storage)
      in Punch::Backup::Recovery::Report  then Result.new(result)
      in Punch::Backup::Recovery::Refused then Restore.failure(result)
      end
    end
  end
end
