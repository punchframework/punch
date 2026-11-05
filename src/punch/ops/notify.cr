module Punch::Ops
  # Notifications are domain events: Punch publishes these from
  # `Ops::Notify`, and alerting is a subscriber of the app's, usually
  # deferred, that mails or calls whoever is on duty. Each is published once
  # when the trouble starts, not again while it lasts, and at least once: a
  # subscriber may see one twice.

  # An error group opened: an exception not seen before, or one that
  # recurred after it was resolved (*reopened*). The message and the
  # backtrace stay in `ops.db` (`Ops.current?.try(&.error(error_id))`):
  # messages often hold values, and an event is a payload.
  struct ErrorOccurred
    include Punch::Event

    getter error_id : Int64
    getter exception : String
    # Where it was handled: the route, `job <Type>`, a subscriber.
    getter source : String
    getter occurrences : Int64
    getter? reopened : Bool

    def initialize(@error_id, @exception, @source, @occurrences, @reopened)
    end
  end

  # Jobs of one type have failed for good (attempts used up) or are
  # parked with a payload this build cannot read. Published again only
  # after none of the type is left in either state.
  struct JobsFailing
    include Punch::Event

    getter job_type : String
    getter failed : Int64
    getter incompatible : Int64

    def initialize(@job_type, @failed, @incompatible)
    end
  end

  # The backup cannot be relied on: a file has not reached its replica
  # for longer than `Backup::Monitor::LAGGING` (*reason* `lagging`, with
  # *database* and *lag_seconds*), or the restore check has not passed
  # for longer than `Notify::VERIFICATION` (`unverified`) or failed last
  # (`verification_failed`), with *last_passed_at*. Published again only
  # after that file caught up or a check passed.
  struct BackupStale
    include Punch::Event

    getter reason : String
    getter database : String?
    getter lag_seconds : Int64?
    getter last_passed_at : Time?

    def initialize(@reason, @database = nil, @lag_seconds = nil, @last_passed_at = nil)
    end
  end

  # Looks for trouble every minute and publishes it as events
  # (`ErrorOccurred`, `JobsFailing`, `BackupStale`), in a transaction of
  # the primary, so deferred subscribers get their jobs through the
  # outbox. What was announced is kept in `ops.db` (`punch_ops_notices`,
  # and per error group), so each trouble is announced once. Does
  # nothing where ops recording is off.
  @[Punch::Job::Recurring(every: 1.minute)]
  struct Notify
    include Punch::Job

    # At most this many error groups are announced per run; more wait for
    # the next.
    ERRORS = 20
    # A restore check that has not passed for this long is stale: it runs
    # daily (`Backup::Verify`), and may take a while.
    VERIFICATION = 26.hours

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      store = Ops.current? || return
      errors = store.unnotified(limit: ERRORS)
      failing, failing_ended = Notify.failing(job.store, store.notices(JOBS))
      stale, stale_ended = Notify.stale(store.notices(BACKUP), Time.utc)
      unless errors.empty? && failing.empty? && stale.empty?
        job.write do |db|
          # Punch's own handle: Punch publishes these, not a Command.
          # ameba:disable Punch/EventsHandle
          events = Events(ErrorOccurred | JobsFailing | BackupStale).for_transaction(db)
          errors.each do |unnotified|
            group = unnotified.group
            events.publish(ErrorOccurred.new(group.id, group.exception, group.source, group.occurrences, unnotified.reopened?))
          end
          failing.each { |_, event| events.publish(event) }
          stale.each { |_, event| events.publish(event) }
        end
      end
      store.notified(errors)
      store.notices(added: failing.map(&.first) + stale.map(&.first), ended: failing_ended + stale_ended)
      wide = Trace.event
      wide.set("punch.ops.notified", errors.size + failing.size + stale.size) if wide.recording?
      nil
    end

    JOBS   = "jobs "
    BACKUP = "backup "

    # Job types that started failing, keyed by their notice, and the
    # notices of types that no longer are.
    def self.failing(queue : Job::Queue, noticed : Array(String)) : {Array({String, JobsFailing}), Array(String)}
      counts = Hash(String, {Int64, Int64}).new { {0_i64, 0_i64} }
      queue.version_counts.each do |count|
        failed, incompatible = counts[count.type]

        case count.state
        when "failed"       then counts[count.type] = {failed + count.jobs, incompatible}
        when "incompatible" then counts[count.type] = {failed, incompatible + count.jobs}
        end
      end
      current = counts.keys.map { |type| JOBS + type }
      started = counts.compact_map do |type, (failed, incompatible)|
        {JOBS + type, JobsFailing.new(type, failed, incompatible)} unless noticed.includes?(JOBS + type)
      end
      {started, noticed - current}
    end

    # What went stale in the backup this process watches
    # (`Backup.monitor`), keyed by notice, and the notices of what
    # recovered. Nothing without a replicated file.
    def self.stale(noticed : Array(String), now : Time,
                   monitor : Backup::Monitor? = Backup.monitor) : {Array({String, BackupStale}), Array(String)}
      return {[] of {String, BackupStale}, [] of String} if monitor.nil? || monitor.litestream.names.empty?

      current = [] of {String, BackupStale}
      monitor.lags.each do |name, lag|
        next unless lag > Backup::Monitor::LAGGING
        current << {"#{BACKUP}lag #{name}", BackupStale.new("lagging", database: name, lag_seconds: lag.total_seconds.to_i64)}
      end
      status = Backup::VerificationStatus.read(monitor.litestream.storage)
      last_passed = status.try(&.last_passed_at)
      if status && !status.passed?
        current << {"#{BACKUP}verification", BackupStale.new("verification_failed", last_passed_at: last_passed)}
      elsif monitor.verification_age(now) > VERIFICATION
        current << {"#{BACKUP}verification", BackupStale.new("unverified", last_passed_at: last_passed)}
      end
      keys = current.map(&.first)
      {current.reject { |key, _| noticed.includes?(key) }, noticed - keys}
    end
  end
end
