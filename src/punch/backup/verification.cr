require "json"
require "file_utils"
require "./restore"
require "./reconciliation"
require "./heartbeat"

module Punch::Backup
  # The recurring restore check failed: a replica could not be restored,
  # a restored file is damaged, or the reconciliation could not run.
  class VerificationFailed < Exception
  end

  # The Litestream setup of this process, for the restore check; set by
  # `serve` and `jobs` when files are replicated.
  class_property current : Litestream? = nil

  # The recurring restore check: restores every replicated file from its
  # replica into a directory of its own in the storage directory, aligned as
  # `punch restore` aligns them (`Restorer#restore_all`), checks each one's
  # integrity, and runs the reconciliation of the restored primary and queue
  # as a dry run. Removes the copies afterwards. Its last result is kept in
  # `verification.json` in the storage directory, for `punch backup` and the
  # metric `punch.backup.verification.age`.
  class Verification
    # The free space a restore must leave on the storage's filesystem: the
    # copies sit next to the live files, which must still be able to grow.
    MINIMUM_FREE = 1_i64 << 30

    alias Restored = Restorer::Restored

    getter started_at : Time
    getter finished_at : Time
    # The time every file was restored to, when a replica was behind
    # (`Restorer.target`); `nil` when each was restored to its latest.
    getter aligned_at : Time?
    getter files : Array(Restored)
    getter reconciliation : Reconciliation?
    getter problems : Array(String)
    # When a check last passed: this one, or the one before it.
    getter last_passed_at : Time?

    def initialize(*, @started_at, @finished_at, @aligned_at, @files, @reconciliation, @problems, @last_passed_at)
    end

    def passed? : Bool
      problems.empty?
    end

    # Restores and checks every file *litestream* replicates; *retention*
    # is the queue's (`PUNCH_JOB_RETENTION_HOURS`), *except* the job that
    # runs the check; *behind* is `Restorer::BEHIND` but in specs. Never
    # raises for what it checks: every failure is one of `problems`. Writes
    # the result to `verification.json`.
    def self.run(litestream : Litestream, retention : Time::Span, *, except : Int64? = nil,
                 behind : Time::Span = Restorer::BEHIND) : Verification
      started = Time.utc
      problems = [] of String
      files = [] of Restored
      aligned = nil
      reconciliation = nil
      directory = File.join(litestream.storage, "verify-#{Random::Secure.hex(6)}")
      begin
        if problem = space_problem(litestream)
          problems << problem
        else
          Dir.mkdir(directory, 0o700)
          aligned, files = Restorer.new(litestream).restore_all(directory, problems, behind: behind)
          reconciliation = reconcile(directory, files, retention, except, problems)
        end
      rescue ex
        problems << "#{ex.class}: #{ex.message}"
      ensure
        FileUtils.rm_rf(directory)
      end
      finished = Time.utc
      previous = VerificationStatus.read(litestream.storage).try(&.last_passed_at)
      verification = new(started_at: started, finished_at: finished, aligned_at: aligned, files: files,
        reconciliation: reconciliation, problems: problems, last_passed_at: problems.empty? ? finished : previous)
      verification.save(litestream.storage)
      verification
    end

    # Why the copies would not fit: they must leave `MINIMUM_FREE` or a
    # tenth of the filesystem free, whichever is more.
    def self.space_problem(litestream : Litestream) : String?
      needed = litestream.names.sum(0_i64) do |name|
        path = litestream.database_path(name)
        (File.info?(path).try(&.size) || 0_i64) + (File.info?("#{path}-wal").try(&.size) || 0_i64)
      end
      total, available = Database::Filesystem.space(litestream.storage) || return
      space_problem(needed, total, available)
    end

    # :nodoc:
    def self.space_problem(needed : Int64, total : Int64, available : Int64) : String?
      reserve = Math.max(MINIMUM_FREE, total // 10)
      return if available - needed >= reserve

      "not enough space to restore next to the live files: #{megabytes(needed)} needed, #{megabytes(available)} available, #{megabytes(reserve)} must stay free"
    end

    private def self.megabytes(bytes : Int64) : String
      "#{(bytes / (1 << 20)).round(1)} MB"
    end

    # The dry run of the reconciliation, when the primary and the queue
    # were both restored intact.
    private def self.reconcile(directory : String, files : Array(Restored), retention : Time::Span,
                               except : Int64?, problems : Array(String)) : Reconciliation?
      Reconciliation.restored(directory, files, retention, except)
    rescue ex : Database::Error
      problems << "the reconciliation could not read the restored files: #{ex.message}"
      nil
    end

    # Writes the result to `verification.json`, replacing it in one step.
    def save(storage : String) : Nil
      path = File.join(storage, VerificationStatus::FILE)
      File.write("#{path}.tmp", to_json)
      File.rename("#{path}.tmp", path)
    rescue File::Error
    end

    # The duration, files, and counts as attributes of *span*, the job's
    # wide event; problems as a `VerificationFailed` error on it.
    def record(span : Trace::Span) : Nil
      if span.recording?
        span.set("punch.backup.verify.passed", passed?)
        span.set("punch.backup.verify.files", files.size)
        span.set("punch.backup.verify.bytes", files.sum(0_i64, &.bytes))
        aligned_at.try { |time| span.set("punch.backup.verify.aligned_at", time.to_rfc3339) }
        files.each do |file|
          span.set("punch.backup.verify.#{file.name}.txid", file.plan.max_txid)
          span.set("punch.backup.verify.#{file.name}.seconds", file.seconds)
        end
        reconciliation.try(&.counts.each { |key, count| span.set("punch.backup.reconcile.#{key}", count) })
        reconciliation.try { |found| span.set("punch.backup.reconcile.findings", found.messages.join('\n')) unless found.empty? }
      end
      span.record_exception(VerificationFailed.new(problems.join('\n')), "punch.backup.verify") unless passed?
    end

    # One line per file and per finding, for people.
    def messages : Array(String)
      lines = files.map do |file|
        "#{file.name}.db: transaction #{file.plan.max_txid.lstrip('0')} of #{file.plan.point.to_rfc3339}, #{file.bytes} bytes in #{file.seconds.round(1)} s, #{file.ok? ? "integrity ok" : "integrity FAILED"}"
      end
      lines.concat(problems)
      if found = reconciliation
        lines << (found.empty? ? "reconciliation (dry run): nothing to do" : "reconciliation (dry run):")
        found.messages.each { |line| lines << "  #{line}" }
      end
      lines
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "passed", passed?
        json.field "started_at", started_at.to_rfc3339
        json.field "finished_at", finished_at.to_rfc3339
        json.field "last_passed_at", last_passed_at.try(&.to_rfc3339)
        json.field "aligned_at", aligned_at.try(&.to_rfc3339)
        json.field "problems", problems
        json.field "files" do
          json.array do
            files.each do |file|
              json.object do
                json.field "name", file.name
                json.field "txid", file.plan.max_txid
                json.field "point", file.plan.point.to_rfc3339
                json.field "replica_files", file.plan.files
                json.field "bytes", file.bytes
                json.field "seconds", file.seconds
                json.field "integrity", file.ok? ? "ok" : file.integrity
              end
            end
          end
        end
        if found = reconciliation
          json.field "reconciliation", found.counts
          json.field "reconciliation_findings", found.messages
        else
          json.field "reconciliation", nil
        end
      end
    end
  end

  # Restores the latest backup every night at 04:00 UTC, at the lowest
  # priority, and checks it (`Verification`). The result goes into the
  # job's wide event (`punch.backup.verify.*`, `punch.backup.reconcile.*`,
  # shown with the run in the ops console); a failed check is recorded as
  # a `Punch::Backup::VerificationFailed` error. Does nothing in a process
  # that replicates nothing.
  @[Punch::Job::Recurring(cron: "0 4 * * *")]
  @[Punch::Job::Options(priority: -100)]
  struct Verify
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      litestream = Backup.current || return
      return if litestream.names.empty?

      Verification.run(litestream, Job::Queue.retention, except: job.id).record(Trace.event)
      nil
    end
  end
end
