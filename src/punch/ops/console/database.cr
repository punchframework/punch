module Punch::Ops::Console
  # ---- Database -----------------------------------------------------------

  # One database file as its signals describe it (`docs/metrics.md`).
  record FileState, name : String, size : Int64?, wal_size : Int64?, wal_frames : Int64?, pending : Int64?,
    checkpoints : Metrics::Distribution?, incomplete : Metrics::Distribution?, lag : Float64?

  # The backup's state: the last restore check and the recovery after a
  # restore, from the storage directory.
  record BackupState, verification : Backup::VerificationStatus?, recovery : Backup::Recovery::Report?,
    last_recovery : Backup::Recovery::Report?

  # A size in bytes as the console shows it.
  def self.bytes(value : Int64?) : String
    return "–" unless value
    return "#{value} B" if value < 1024
    return "#{(value / 1024).round(1)} KiB" if value < 1_048_576

    "#{(value / 1_048_576).round(1)} MiB"
  end

  # A distribution of durations in seconds as "count, average, max".
  def self.durations(distribution : Metrics::Distribution?) : String
    return "–" unless distribution && distribution.count > 0

    "#{distribution.count}, average #{ms(distribution.sum / distribution.count * 1000)}, max #{ms(distribution.max * 1000)}"
  end

  # One metric point's value as text.
  def self.metric(value : Int64 | Float64 | Metrics::Distribution) : String
    case value
    in Int64   then value.to_s
    in Float64 then value.round(3).to_s
    in Metrics::Distribution
      value.count > 0 ? "#{value.count} values, sum #{value.sum.round(3)}, max #{value.max.round(3)}" : "no values"
    end
  end

  struct DatabaseOverview
    include Punch::Component

    def initialize(@files : Array(FileState), @backup : BackupState?, @series : Array(Metrics::Series), @now : Time)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Database") do
        v.h1 "Database"
        files(v)
        backup(v)
        metrics(v)
      end
    end

    private def files(v : Punch::View) : Nil
      v.section do
        v.h2 "Files"
        if @files.empty?
          v.p "No database reports signals in this process."
          return
        end
        columns = ["File", "Size", "WAL", "WAL frames", "Writes waiting", "Checkpoints", "Incomplete checkpoints", "Replica lag"]
        v.table(class: "files") do
          v.thead { v.tr { columns.each { |label| v.th label, scope: "col" } } }
          v.tbody do
            @files.each do |file|
              v.tr do
                v.th "#{file.name}.db", scope: "row"
                v.td Console.bytes(file.size)
                v.td Console.bytes(file.wal_size)
                v.td file.wal_frames.try(&.to_s) || "–"
                v.td file.pending.try(&.to_s) || "–"
                v.td Console.durations(file.checkpoints)
                v.td Console.durations(file.incomplete)
                v.td file.lag.try { |lag| "#{lag.round(1)} s" } || "not replicated"
              end
            end
          end
        end
      end
    end

    private def backup(v : Punch::View) : Nil
      v.section do
        v.h2 "Backup"
        unless backup = @backup
          v.p "This process has no storage directory (it does not serve)."
          return
        end
        if recovery = backup.recovery
          v.p do
            v.strong "Recovery mode: "
            v.text "the files were restored #{Console.time(recovery.restored_at)}; background work waits until the reconciliation is confirmed. "
            v.a "Review and confirm", href: RecoveryPage.href
          end
        end
        v.dl(class: "facts") do
          v.dt "Last restore check"
          if status = backup.verification
            v.dd "#{status.passed? ? "passed" : "failed"} #{Console.time(status.finished_at)}"
            v.dt "Last passed"
            v.dd Console.time(status.last_passed_at)
            unless status.problems.empty?
              v.dt "Problems"
              v.dd { v.ul { status.problems.each { |problem| v.li problem } } }
            end
            status.reconciliation.try do |counts|
              v.dt "Reconciliation (dry run)"
              v.dd counts.map { |list, count| "#{list} #{count}" }.join(", ")
            end
          else
            v.dd "none yet (Punch::Backup::Verify runs at 04:00 UTC; punch backup:verify runs it now)"
          end
          v.dt "Last recovery"
          if last = backup.last_recovery
            v.dd { v.a "restored #{Console.time(last.restored_at)}, confirmed #{Console.time(last.confirmed_at)}", href: RecoveryPage.href }
          else
            v.dd "none"
          end
        end
      end
    end

    private def metrics(v : Punch::View) : Nil
      v.section do
        v.h2 "Metrics"
        if @series.empty?
          v.p "No metric is registered in this process."
          return
        end
        v.p "Every instrument of this process, as the OTLP exporter reads it (lib/punch/docs/metrics.md)."
        v.table(class: "metrics") do
          v.thead { v.tr { ["Name", "Attributes", "Value", "Unit"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            @series.each do |series|
              series.points.each do |point|
                v.tr do
                  v.td { v.code series.name }
                  v.td point.attributes.map { |key, value| "#{key}=#{value}" }.join(", ")
                  v.td Console.metric(point.value)
                  v.td series.unit
                end
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/database`: each database file's size, WAL, waiting
  # writes, checkpoints, and replica lag; the last restore check and
  # recovery; and every metric of the process.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/database")]
  struct DatabasePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = DatabaseOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      series = Metrics.registry.collect
      backup = Backup.storage.try do |storage|
        BackupState.new(Backup::VerificationStatus.read(storage), Backup::Recovery.read(storage), Backup::Recovery.last(storage))
      end
      DatabaseOverview.new(DatabasePage.files(series), backup, series, Time.utc)
    end

    # The files named by `db.namespace` in *series*, with their signals.
    def self.files(series : Array(Metrics::Series)) : Array(FileState)
      by_name = series.to_h { |one| {one.name, one} }
      names = series.flat_map(&.points.compact_map(&.attributes["db.namespace"]?.as?(String))).uniq!
      names.map do |name|
        FileState.new(name, int(by_name, "punch.db.size", name), int(by_name, "punch.db.wal.size", name),
          int(by_name, "punch.db.wal.frames", name), int(by_name, "db.client.connection.pending_requests", name),
          distribution(by_name, name, true), distribution(by_name, name, false),
          point(by_name, "punch.backup.lag", name).try(&.value.as?(Float64)))
      end
    end

    private def self.point(series : Hash(String, Metrics::Series), metric : String, name : String,
                           complete : Bool? = nil) : Metrics::Point?
      series[metric]?.try &.points.find do |point|
        point.attributes["db.namespace"]? == name && (complete.nil? || point.attributes["punch.db.checkpoint.complete"]? == complete)
      end
    end

    private def self.int(series : Hash(String, Metrics::Series), metric : String, name : String) : Int64?
      point(series, metric, name).try(&.value.as?(Int64))
    end

    private def self.distribution(series : Hash(String, Metrics::Series), name : String, complete : Bool) : Metrics::Distribution?
      point(series, "punch.db.checkpoint.duration", name, complete).try(&.value.as?(Metrics::Distribution))
    end
  end

  # ---- Recovery -----------------------------------------------------------

  struct RecoveryDetail
    include Punch::Component

    def initialize(@report : Backup::Recovery::Report?, @last : Backup::Recovery::Report?)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Recovery") do
        v.h1 "Recovery"
        if report = @report
          v.p "The files were restored #{Console.time(report.restored_at)}. Requests are served; job workers, the outbox relay, and recurring jobs wait until the reconciliation below is confirmed."
          report(v, report)
          v.p "Confirming applies these lists by ID, to the entries and jobs still as the report saw them, and starts background work in every process within seconds. A job enqueued without the outbox cannot be matched: look at the jobs page before you confirm."
          v.form(ConfirmRecovery.action) { |form| form.submit "Confirm and resume background work" }
        elsif last = @last
          v.p "No restore waits for confirmation. The last recovery:"
          report(v, last)
        else
          v.p "No restore waits for confirmation, and none was made from this storage directory (punch restore)."
        end
      end
    end

    private def report(v : Punch::View, report : Backup::Recovery::Report) : Nil
      v.dl(class: "facts") do
        v.dt "Restored"
        v.dd Console.time(report.restored_at)
        report.requested.try { |time| v.dt "Asked for"; v.dd Console.time(time) }
        report.aligned_at.try { |time| v.dt "Aligned to"; v.dd Console.time(time) }
        report.replaced.try { |path| v.dt "Replaced files"; v.dd { v.code path } }
        report.confirmed_at.try { |time| v.dt "Confirmed"; v.dd Console.time(time) }
        report.applied.try { |applied| v.dt "Changed"; v.dd applied.map { |list, count| "#{list} #{count}" }.join(", ") }
      end
      v.h2 "Files"
      v.table(class: "restored") do
        v.thead { v.tr { ["File", "Up to", "Transaction", "Bytes"].each { |label| v.th label, scope: "col" } } }
        v.tbody do
          report.files.each do |plan|
            v.tr do
              v.th "#{plan.name}.db", scope: "row"
              v.td Console.time(plan.point)
              v.td { v.code plan.max_txid.lstrip('0') }
              v.td Console.bytes(plan.bytes)
            end
          end
        end
      end
      v.h2 "Reconciliation"
      found = report.reconciliation
      unless found
        v.p "None: the primary or the queue is not replicated."
        return
      end
      if found.empty?
        v.p "Nothing to do: the primary and the queue agree."
      end
      entries(v, "Hand over again (the queue lost their jobs)", found.reenqueue)
      jobs(v, "Discard (their Command is not in the primary)", found.discard)
      jobs(v, "Ran for a Command not in the primary (nothing to do)", found.orphaned)
      jobs(v, "Run again (their writes may be gone)", found.rerun)
      jobs(v, "Interrupted (ready again)", found.interrupted)
      v.p "#{found.pending} outbox entries were not handed over yet; the relay hands them over as usual." if found.pending > 0
    end

    private def entries(v : Punch::View, title : String, entries : Array(Backup::Reconciliation::Entry)) : Nil
      return if entries.empty?

      v.h3 "#{title}: #{entries.size}"
      v.table do
        v.thead { v.tr { ["Entry", "Type", "Queue", "Written", "Handed over"].each { |label| v.th label, scope: "col" } } }
        v.tbody do
          entries.each do |entry|
            v.tr do
              v.td entry.id.to_s
              v.td { v.code entry.type }
              v.td entry.queue
              v.td Console.time(entry.created_at)
              v.td Console.time(entry.handed_over_at)
            end
          end
        end
      end
    end

    private def jobs(v : Punch::View, title : String, jobs : Array(Backup::Reconciliation::Job)) : Nil
      return if jobs.empty?

      v.h3 "#{title}: #{jobs.size}"
      v.table do
        v.thead { v.tr { ["Job", "Type", "Queue", "State", "Enqueued", "Finished"].each { |label| v.th label, scope: "col" } } }
        v.tbody do
          jobs.each do |job|
            v.tr do
              v.td { v.a job.id.to_s, href: JobPage.href(job_id: job.id) }
              v.td { v.code job.type }
              v.td job.queue
              v.td job.state
              v.td Console.time(job.enqueued_at)
              v.td Console.time(job.finished_at)
            end
          end
        end
      end
    end
  end

  # `GET /_punch/recovery`: the restore waiting for confirmation with its
  # reconciliation, or the last recovery.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/recovery")]
  @[Punch::Forms(ConfirmRecovery)]
  struct RecoveryPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = RecoveryDetail

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      storage = Backup.storage || return RecoveryDetail.new(nil, nil)
      RecoveryDetail.new(Backup::Recovery.read(storage), Backup::Recovery.last(storage))
    end
  end

  # What confirming a recovery answers: how many entries and jobs each
  # list changed.
  struct Recovered
    include JSON::Serializable

    getter applied : Hash(String, Int64)

    def initialize(@applied)
    end
  end

  # 409: the reconciliation could not be applied; recovery mode continues.
  @[Punch::Status(409)]
  struct NotConfirmed
    include JSON::Serializable

    getter reason : String

    def initialize(@reason)
    end
  end

  # `POST /_punch/recovery/confirm`: applies the reconciliation of the
  # restore waiting for confirmation and ends recovery mode, as `punch
  # recovery:confirm` does. 404 when none waits.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/recovery/confirm")]
  struct ConfirmRecovery < Punch::Command
    struct Input
      include Punch::Input
    end

    alias Output = Recovered | NotFound | NotConfirmed

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(ConfirmRecovery)) : Output
      storage = Backup.storage || return NotFound.new
      queue = Job::Queue.current? || return NotFound.new

      case confirmed = Backup::Recovery.confirm(storage, queue, db, Time.utc)
      in Backup::Recovery::Report  then Recovered.new(confirmed.applied || {} of String => Int64)
      in Backup::Recovery::Refused then confirmed.code == "not_recovering" ? NotFound.new : NotConfirmed.new(confirmed.code)
      end
    end
  end
end
