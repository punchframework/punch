require "json"
require "file_utils"
require "./restore"
require "./reconciliation"

module Punch::Backup
  # `punch restore` and the recovery mode after it.
  #
  # A restore brings every replicated file back into the storage
  # directory, aligned as the restore check aligns them
  # (`Restorer#restore_all`), while no process has the files open. The
  # files it replaces are moved aside, never deleted, and the report goes
  # to `recovery.json`. While that file exists the app is in recovery
  # mode: `serve` and `jobs` serve requests but start no job workers, no
  # outbox relay, and no recurring schedules (`Hold`), because background
  # work is where a restore's skew between the files does damage. A person
  # or an agent reads the reconciliation (`punch recovery`) and confirms
  # it (`punch recovery:confirm`, `confirm`): it is applied, the report
  # moves to `recovered.json`, and background work starts in every
  # running process.
  module Recovery
    Log = ::Log.for("punch.backup")

    # The report of a restore waiting for confirmation: recovery mode.
    FILE = "recovery.json"
    # The report of the last confirmed recovery.
    CONFIRMED = "recovered.json"
    # Held shared by every process that opens the storage's files (`serve`,
    # `jobs`) and exclusively by a restore.
    LOCK = "punch.lock"
    # Written while a restore swaps files; a process refuses to start
    # while it exists.
    INCOMPLETE = "restore-incomplete.json"

    # Why a restore or a confirmation did not happen; nothing in the
    # storage directory changed.
    record Refused, code : String, message : String, problems : Array(String) = [] of String

    # What a restore did, and once confirmed, what the confirmation
    # changed.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Report
      include JSON::Serializable

      getter restored_at : Time
      # The time asked for (`punch restore --at`); `nil` for the latest.
      getter requested : Time?
      # The time every file was restored to when a replica was behind
      # (`Restorer.target`); `nil` when each went to its latest point (or
      # to its last point at `requested`).
      getter aligned_at : Time?
      getter files : Array(Restorer::Plan)
      # Where the files the restore replaced were moved; `nil` when the
      # storage directory had none.
      getter replaced : String?
      # `nil` when the primary or the queue is not replicated.
      getter reconciliation : Reconciliation?
      getter confirmed_at : Time?
      # How many entries and jobs the confirmation changed, per list.
      getter applied : Hash(String, Int64)?

      def initialize(*, @restored_at, @requested, @aligned_at, @files, @replaced, @reconciliation,
                     @confirmed_at = nil, @applied = nil)
      end

      def confirmed(at : Time, applied : Hash(String, Int64)) : Report
        Report.new(restored_at: restored_at, requested: requested, aligned_at: aligned_at, files: files,
          replaced: replaced, reconciliation: reconciliation, confirmed_at: at, applied: applied)
      end

      # One line per file and per list of the reconciliation, for people.
      def messages : Array(String)
        lines = files.map do |plan|
          "#{plan.name}.db: transaction #{plan.max_txid.lstrip('0')} of #{plan.point.to_rfc3339}"
        end
        lines << "replaced files moved to #{replaced}" if replaced
        if found = reconciliation
          lines << (found.empty? ? "reconciliation: nothing to do" : "reconciliation:")
          found.messages.each { |line| lines << "  #{line}" }
        else
          lines << "no reconciliation: the primary or the queue is not replicated"
        end
        lines
      end

      # Writes the report to *path*, replacing it in one step.
      def save(path : String) : Nil
        File.write("#{path}.tmp", to_json)
        File.rename("#{path}.tmp", path)
      end
    end

    # Whether a restore in *storage* waits for confirmation.
    def self.pending?(storage : String) : Bool
      File.exists?(File.join(storage, FILE))
    end

    # The restore waiting for confirmation, or `nil`.
    def self.read(storage : String) : Report?
      read_file(File.join(storage, FILE))
    end

    # The last confirmed recovery, or `nil`.
    def self.last(storage : String) : Report?
      read_file(File.join(storage, CONFIRMED))
    end

    private def self.read_file(path : String) : Report?
      Report.from_json(File.read(path))
    rescue File::Error | JSON::ParseException | JSON::SerializableError
      nil
    end

    # Why the files in *storage* must not be opened: a restore stopped
    # while it swapped them. `nil` otherwise.
    def self.incomplete(storage : String) : String?
      path = File.join(storage, INCOMPLETE)
      return unless File.exists?(path)

      "A restore stopped while it replaced the files in #{storage} (#{path}): run punch restore again; the files it had replaced are in #{read_marker(path) || "a replaced-* directory there"}."
    end

    private def self.read_marker(path : String) : String?
      JSON.parse(File.read(path))["replaced"].as_s?
    rescue File::Error | JSON::ParseException | KeyError
      nil
    end

    @@shared = {} of String => File
    @@shared_lock = Mutex.new

    # Takes the shared lock on *storage* for the life of the process, as
    # `serve` and `jobs` do before they open its files; `false` while a
    # restore holds it.
    def self.share(storage : String) : Bool
      path = File.expand_path(File.join(storage, LOCK))
      @@shared_lock.synchronize do
        return true if @@shared.has_key?(path)

        file = File.open(path, "a")
        begin
          file.flock_shared(blocking: false)
        rescue IO::Error
          file.close
          return false
        end
        @@shared[path] = file
        true
      end
    end

    # The plans of a restore of every file *litestream* replicates, to the
    # latest point or to *at*, aligned as the restore would be; downloads
    # nothing.
    def self.plan(litestream : Litestream, *, at : Time? = nil, behind : Time::Span = Restorer::BEHIND) : {Time?, Array(Restorer::Plan)} | Refused
      problems = [] of String
      aligned, plans = Restorer.new(litestream).plan_all(File.join(litestream.storage, "restore-plan"), problems, at: at, behind: behind)
      return Refused.new("restore_failed", "The replicas cannot be planned.", problems) unless problems.empty?

      {aligned, plans}
    end

    # Restores every file *litestream* replicates into its storage
    # directory, to the latest point or to *at*: into a scratch directory
    # first, each file checked (`Restorer#restore_all`) and the
    # reconciliation of the restored primary and queue computed; then the
    # files in the storage directory (with `cache.db`, which holds values
    # computed from the replaced data, and Litestream's local state) are
    # moved to `replaced-<time>/`, the restored ones moved in, and the
    # report saved as `recovery.json`. Refused while a process has the
    # storage open (`share`) or a Litestream runs on it, and when a file
    # cannot be restored intact; nothing changes then. *retention* is the
    # queue's (`PUNCH_JOB_RETENTION_HOURS`).
    def self.restore(litestream : Litestream, retention : Time::Span, *, at : Time? = nil,
                     behind : Time::Span = Restorer::BEHIND) : Report | Refused
      storage = litestream.storage
      Dir.mkdir_p(storage, 0o700)
      storage_lock = exclusive(File.join(storage, LOCK)) ||
                     return Refused.new("app_running", "A process has the files in #{storage} open: stop serve and jobs before restoring.")
      begin
        litestream_lock = exclusive(litestream.lock_path) ||
                          return Refused.new("litestream_running", "A Litestream replicates the files in #{storage} (#{litestream.lock_path} is locked), perhaps left by a process that was killed: stop it before restoring.")
        begin
          restore_into(litestream, storage, retention, at, behind)
        ensure
          litestream_lock.close
        end
      ensure
        storage_lock.close
      end
    end

    private def self.restore_into(litestream : Litestream, storage : String, retention : Time::Span, at : Time?,
                                  behind : Time::Span) : Report | Refused
      directory = File.join(storage, "restore-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory, 0o700)
      begin
        problems = [] of String
        aligned, files = Restorer.new(litestream).restore_all(directory, problems, at: at, behind: behind)
        return Refused.new("restore_failed", "Nothing was replaced: the replicas cannot be restored intact.", problems) unless problems.empty?

        reconciliation = begin
          Reconciliation.restored(directory, files, retention)
        rescue ex : Database::Error
          return Refused.new("restore_failed", "Nothing was replaced: the restored files cannot be read (#{ex.message}).")
        end
        restored_at = Time.utc
        replaced = swap(storage, directory, litestream.names, restored_at)
        report = Report.new(restored_at: restored_at, requested: at, aligned_at: aligned, files: files.map(&.plan),
          replaced: replaced, reconciliation: reconciliation)
        report.save(File.join(storage, FILE))
        File.delete?(File.join(storage, INCOMPLETE))
        report
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    # The files a restore moves aside for each restored *name*: the file,
    # its WAL and shared memory, and Litestream's local state.
    private def self.companions(name : String) : Array(String)
      ["#{name}.db", "#{name}.db-wal", "#{name}.db-shm", ".#{name}.db-litestream"]
    end

    # Moves the files of *names* and `cache.db` (and a report waiting for
    # confirmation, which the new one replaces) from *storage* into a new
    # `replaced-<time>` directory, then the restored files from
    # *directory* into *storage*. Returns the new directory, or `nil` when
    # there was nothing to move. A marker file makes processes refuse to
    # start until the swap is done.
    private def self.swap(storage : String, directory : String, names : Array(String), at : Time) : String?
      old = (names + ["cache"]).flat_map { |name| companions(name) } + [FILE]
      present = old.select { |file| File.exists?(File.join(storage, file)) }
      replaced = present.empty? ? nil : File.join(storage, "replaced-#{at.to_s("%Y%m%dT%H%M%SZ")}-#{Random::Secure.hex(2)}")
      File.write(File.join(storage, INCOMPLETE), {replaced: replaced, restored: directory}.to_json)
      if replaced
        Dir.mkdir(replaced, 0o700)
        present.each { |file| File.rename(File.join(storage, file), File.join(replaced, file)) }
      end
      names.each do |name|
        companions(name).first(3).each do |file|
          File.rename(File.join(directory, file), File.join(storage, file)) if File.exists?(File.join(directory, file))
        end
      end
      replaced
    end

    # *path* opened and locked exclusively, or `nil` while someone else
    # holds a lock on it.
    private def self.exclusive(path : String) : File?
      file = File.open(path, "a")
      begin
        file.flock_exclusive(blocking: false)
        file
      rescue IO::Error
        file.close
        nil
      end
    end

    # Applies the reconciliation of the restore waiting in *storage* to its
    # files, and ends recovery mode: entries to hand over again are marked
    # pending (the relay hands them over), jobs to discard are discarded,
    # jobs to run again and interrupted ones are made ready (`Job::Queue#reconcile`).
    # Only entries and jobs still as the report saw them change. Works
    # while the app runs: its processes start background work within
    # `Hold::POLL` once the report is gone.
    def self.confirm(storage : String) : Report | Refused
      report = read(storage) || return Refused.new("not_recovering", "No restore waits for confirmation in #{storage}.")
      applied = begin
        if found = report.reconciliation
          open(storage, "queue") do |queue_db|
            apply(found, report.restored_at, Job::Queue.new(queue_db)) do |ids|
              open(storage, "primary") { |primary| primary.write { |db| Job::Outbox.hand_over_again(db, ids) } }
            end
          end
        else
          {} of String => Int64
        end
      rescue ex : Database::Error | Job::Queue::Error
        return Refused.new("confirm_failed", "The reconciliation could not be applied (#{ex.message}); recovery mode continues, try again.")
      end
      finish(storage, report, applied, Time.utc)
    end

    # The same from inside the running app (the ops console): *queue* is
    # the process's own, and the outbox entries are handed over again in
    # *primary*, the write transaction the console's Command holds, rather
    # than through a second connection that would wait for it.
    def self.confirm(storage : String, queue : Job::Queue, primary : Writer, now : Time) : Report | Refused
      report = read(storage) || return Refused.new("not_recovering", "No restore waits for confirmation in #{storage}.")
      applied = begin
        if found = report.reconciliation
          apply(found, report.restored_at, queue) { |ids| Job::Outbox.hand_over_again(primary, ids) }
        else
          {} of String => Int64
        end
      rescue ex : Database::Error | Job::Queue::Error
        return Refused.new("confirm_failed", "The reconciliation could not be applied (#{ex.message}); recovery mode continues, try again.")
      end
      finish(storage, report, applied, now)
    end

    # Applies *found* to *queue*, and hands the entries to enqueue again
    # to the block, which marks them in the primary and says how many.
    private def self.apply(found : Reconciliation, restored_at : Time, queue : Job::Queue, & : Array(Int64) -> Int64) : Hash(String, Int64)
      discarded, rerun, released = queue.reconcile(found.discard.map(&.id), found.rerun.map(&.id),
        found.interrupted.map(&.id), restored_at)
      applied = {"discard" => discarded, "rerun" => rerun, "interrupted" => released}
      applied["reenqueue"] = found.outbox? && !found.reenqueue.empty? ? yield(found.reenqueue.map(&.id)) : 0_i64
      applied
    end

    private def self.finish(storage : String, report : Report, applied : Hash(String, Int64), at : Time) : Report
      confirmed = report.confirmed(at, applied)
      confirmed.save(File.join(storage, CONFIRMED))
      File.delete(File.join(storage, FILE))
      confirmed
    end

    private def self.open(storage : String, name : String, & : Database -> T) : T forall T
      database = Database.open(File.join(storage, "#{name}.db"), name: name, config: Database::Config.new(readers: 1))
      begin
        yield database
      ensure
        database.close
      end
    end

    # Holds back a process's background work (job workers, the outbox
    # relay, recurring schedules) while a restore waits for confirmation,
    # and starts it once `recovery.json` is gone. Requests are served
    # meanwhile: Commands write outbox entries, which wait.
    class Hold
      # How often a held process looks whether the restore was confirmed.
      POLL = 2.seconds

      @stop = Channel(Nil).new
      @lock = Mutex.new
      @held = Atomic(Bool).new(false)
      @stopped = false

      def initialize(@storage : String, @poll : Time::Span = POLL)
      end

      # Whether background work is held back now.
      def held? : Bool
        @held.get
      end

      # Runs *resume* now, or once the restore is confirmed, unless `stop`
      # comes first.
      def start(&resume : ->) : Nil
        unless Recovery.pending?(@storage)
          resume.call
          return
        end
        @held.set(true)
        Log.warn { "recovery mode: a restore waits for confirmation (punch recovery); job workers, the outbox relay, and recurring schedules start once it is confirmed (punch recovery:confirm)" }
        spawn(name: "punch.backup.recovery") do
          loop do
            select
            when @stop.receive?
              break
            when timeout(@poll)
              next if Recovery.pending?(@storage)
              @lock.synchronize do
                unless @stopped
                  @held.set(false)
                  Log.info { "recovery confirmed: background work starts" }
                  resume.call
                end
              end
              break
            end
          end
        end
      end

      # Stops waiting; background work held back is not started.
      def stop : Nil
        @lock.synchronize { @stopped = true }
        @stop.close
      end

      # Registers `punch.backup.recovery`: 1 while background work is
      # held back.
      def observe(registry : Metrics::Registry = Metrics.registry) : Nil
        registry.observe("punch.backup.recovery", :gauge, "1",
          "1 while a restore waits for confirmation and job workers, the outbox relay, and schedules are stopped") do |recorder|
          recorder.record(held? ? 1_i64 : 0_i64, Metrics::Attributes.new)
        end
      end
    end
  end
end
