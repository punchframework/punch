require "json"

module Punch::Backup
  # What background work needs after `primary.db` and `queue.db` were
  # restored to slightly different points. Each file is replicated on its
  # own, so the queue can be older than the primary (outbox entries handed
  # over to jobs the queue never got) or newer (jobs for Commands the
  # primary does not have, and finished jobs whose writes to the primary are
  # gone).
  #
  # Reads both files and changes nothing: the recurring restore check
  # shows it as a dry run; after `punch restore`, `Recovery.confirm`
  # applies it once a person or an agent confirms.
  #
  # | List | Jobs or entries | Proposed |
  # |---|---|---|
  # | `reenqueue` | Outbox entries marked as handed over, with no job in the queue | Hand over again |
  # | `discard` | Unfinished jobs from an outbox entry the primary does not have | Discard |
  # | `orphaned` | Finished jobs from an outbox entry the primary does not have | Nothing: what they did outside cannot be taken back; for review |
  # | `rerun` | Jobs that finished within `MARGIN` of the primary's point or after it: their writes may be gone | Run again |
  # | `interrupted` | Jobs running at the queue's point | Ready again (as after a crash) |
  #
  # Entries and jobs older than the retention window may already be
  # purged on one side, so only those within it are compared. A job
  # enqueued without an outbox (by another job, or a schedule) cannot be
  # matched; it shows only as rerun or interrupted.
  struct Reconciliation
    include JSON::Serializable

    # Writes within this much of the primary's point may be missing from
    # it: the point is the time of the last replica file restored, given
    # to the second, and that file holds up to one sync interval (1 s) of
    # commits. Running a job again is safe (jobs run at least once), so
    # the margin errs wide.
    MARGIN = 5.seconds

    # Unfinished states: a job in one of them would still run.
    UNFINISHED = %w[ready blocked running failed incompatible]
    # Finished states whose writes may be lost.
    FINISHED = %w[done discarded]

    record Entry, id : Int64, key : String, queue : String, type : String, created_at : Time,
      handed_over_at : Time? do
      include JSON::Serializable
    end

    record Job, id : Int64, queue : String, type : String, state : String, unique_key : String?,
      enqueued_at : Time, finished_at : Time? do
      include JSON::Serializable

      # The outbox entry's key, for a job handed over from one.
      def outbox_key : String?
        unique_key.try(&.lchop?("outbox:"))
      end
    end

    getter reenqueue : Array(Entry)
    getter discard : Array(Job)
    getter orphaned : Array(Job)
    getter rerun : Array(Job)
    getter interrupted : Array(Job)
    # Entries not handed over yet: the relay hands them over as usual
    # (the queue ignores keys it has).
    getter pending : Int64
    # Whether the primary has an outbox; without one, only `rerun` and
    # `interrupted` can be known.
    getter? outbox : Bool

    def initialize(*, @reenqueue = [] of Entry, @discard = [] of Job, @orphaned = [] of Job,
                   @rerun = [] of Job, @interrupted = [] of Job, @pending = 0_i64, @outbox = true)
    end

    # Compares the restored *primary* (reaching *primary_point*) with the
    # restored *queue* (reaching *queue_point*). Jobs and entries older
    # than *retention* before either point are left out, as they may be
    # purged. *except* leaves out one job, the restore check's own.
    def self.compare(primary : Database, queue : Database, *, primary_point : Time, queue_point : Time,
                     retention : Time::Span, except : Int64? = nil) : self
      outbox = Punch::Job::Outbox.present?(primary)
      entries = outbox ? entries(primary) : [] of Entry
      jobs = jobs(queue, Math.min(primary_point, queue_point) - retention).reject { |job| job.id == except }
      keys = entries.to_set(&.key)
      queued = jobs.compact_map(&.outbox_key).to_set
      # Gone from the primary: an outbox job younger than the primary's
      # window whose entry is missing. Older entries may be purged.
      missing = outbox ? jobs.select { |job| (key = job.outbox_key) && !keys.includes?(key) && job.enqueued_at >= primary_point - retention } : [] of Job
      gone = missing.to_set(&.id)
      new(
        # The queue purges a job no earlier than its entry is handed over,
        # so within the queue's window an entry without a job lost it.
        reenqueue: entries.select { |entry| (at = entry.handed_over_at) && at >= queue_point - retention && !queued.includes?(entry.key) },
        discard: missing.select(&.state.in?(UNFINISHED)),
        orphaned: missing.select(&.state.in?(FINISHED)),
        rerun: jobs.select { |job| job.state.in?(FINISHED) && !gone.includes?(job.id) && (at = job.finished_at) && at > primary_point - MARGIN },
        interrupted: jobs.select { |job| job.state == "running" && !gone.includes?(job.id) },
        pending: entries.count { |entry| entry.handed_over_at.nil? }.to_i64,
        outbox: outbox)
    end

    # The reconciliation of the files `Restorer#restore_all` restored into
    # *directory* as *files*, when the primary and the queue were both
    # restored intact; `nil` otherwise.
    def self.restored(directory : String, files : Array(Restorer::Restored), retention : Time::Span,
                      except : Int64? = nil) : self?
      primary = files.find { |file| file.name == "primary" && file.ok? } || return
      queue = files.find { |file| file.name == "queue" && file.ok? } || return
      Restorer.open(File.join(directory, "primary.db")) do |primary_db|
        Restorer.open(File.join(directory, "queue.db")) do |queue_db|
          compare(primary_db, queue_db, primary_point: primary.plan.point, queue_point: queue.plan.point,
            retention: retention, except: except)
        end
      end
    end

    private def self.entries(primary : Database) : Array(Entry)
      primary.read do |db|
        db.query_all("SELECT id, key, queue, type, created_at, handed_over_at FROM punch_outbox ORDER BY id",
          name: "Punch::Backup::Reconciliation.entries") do |row|
          Entry.new(row.read(Int64), row.read(String), row.read(String), row.read(String), Time.unix_ms(row.read(Int64)),
            row.read(Int64?).try { |millis| Time.unix_ms(millis) })
        end
      end
    end

    # Unfinished jobs, and finished ones since *since*.
    private def self.jobs(queue : Database, since : Time) : Array(Job)
      queue.read do |db|
        db.query_all(<<-SQL, since.to_unix_ms, name: "Punch::Backup::Reconciliation.jobs") do |row|
          SELECT id, queue, type, state, unique_key, enqueued_at, finished_at FROM punch_jobs
          WHERE finished_at IS NULL OR finished_at >= ?
          ORDER BY id
          SQL
          Job.new(row.read(Int64), row.read(String), row.read(String), row.read(String), row.read(String?),
            Time.unix_ms(row.read(Int64)), row.read(Int64?).try { |millis| Time.unix_ms(millis) })
        end
      end
    end

    # Whether nothing needs doing.
    def empty? : Bool
      reenqueue.empty? && discard.empty? && orphaned.empty? && rerun.empty? && interrupted.empty?
    end

    # How many of each, as `punch.backup.reconcile.*` attributes and in
    # reports.
    def counts : Hash(String, Int64)
      {
        "reenqueue" => reenqueue.size.to_i64, "discard" => discard.size.to_i64, "orphaned" => orphaned.size.to_i64,
        "rerun" => rerun.size.to_i64, "interrupted" => interrupted.size.to_i64, "pending" => pending,
      }
    end

    # One line per list that is not empty, with up to *sample* entries.
    def messages(sample : Int32 = 5) : Array(String)
      lines = [] of String
      lines << "no outbox in the primary: only finished and running jobs compared" unless outbox?
      lines << line("to hand over again (handed over, no job)", reenqueue.map { |entry| "#{entry.type} (outbox #{entry.id})" }, sample)
      lines << line("to discard (their Command is not in the primary)", discard.map { |job| describe(job) }, sample)
      lines << line("ran for a Command not in the primary (for review)", orphaned.map { |job| describe(job) }, sample)
      lines << line("to run again (finished at or after the primary's point)", rerun.map { |job| describe(job) }, sample)
      lines << line("interrupted (running at the queue's point)", interrupted.map { |job| describe(job) }, sample)
      lines.reject(&.empty?)
    end

    private def line(title : String, items : Array(String), sample : Int32) : String
      return "" if items.empty?

      shown = items.first(sample).join(", ")
      "#{items.size} #{title}: #{shown}#{items.size > sample ? ", …" : ""}"
    end

    private def describe(job : Job) : String
      "#{job.type} (job #{job.id}, #{job.state})"
    end
  end
end
