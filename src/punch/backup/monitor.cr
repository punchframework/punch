module Punch::Backup
  # A replicated file has not reached its replica for longer than
  # `Monitor::LAGGING`.
  class Lagging < Exception
  end

  # The replica's bucket is not known to encrypt what it stores.
  class NotEncrypted < Exception
  end

  # How far each replica is behind, the health of the backup, and the
  # bucket's encryption, for one process. Every process with the databases
  # open runs one, whether or not its own sidecar replicates: it asks
  # whichever Litestream answers on the control socket.
  #
  # **Lag** of a file: zero when nothing changed since Litestream's last
  # successful upload (`last_sync_at`); otherwise the time since that
  # upload. A change is the WAL file's modification time, so writes from
  # every process count. Its resolution is about one sync interval (1 s).
  # While no Litestream answers, the lag grows from the last upload this
  # process saw, or from its start.
  class Monitor
    # A lag above this is reported once as a `Lagging` error.
    LAGGING = 5.minutes
    # How often the lag is measured.
    INTERVAL = 15.seconds
    # How often the bucket is asked again: after an answer, and after none.
    RECHECK = 6.hours
    RETRY   = 5.minutes

    getter litestream : Litestream
    getter environment : String
    # The files of this process that need a replica and lack one.
    getter missing : Array(String)
    @lags = {} of String => Time::Span
    @synced = {} of String => Time
    @lagging = Set(String).new
    @encryption : Encryption::Result? = nil
    @lock = Mutex.new
    @stop = Channel(Nil).new
    @since : Time

    def initialize(@litestream : Litestream, names : Enumerable(String), @environment : String,
                   @tracer : Trace::Tracer = Trace::Tracer.off, @env : Hash(String, String)? = nil,
                   @sidecar : Sidecar? = nil, now : Time = Time.utc)
      @missing = litestream.config.missing(names)
      @since = now
    end

    # Whether a missing replica fails the health check: everywhere except
    # development and test, where replication is off unless configured.
    def required? : Bool
      !environment.in?("development", "test")
    end

    # Measures the lag every `INTERVAL` and checks the bucket's encryption,
    # in fibers of their own, until `stop`.
    def start : Nil
      return if litestream.names.empty?

      spawn(name: "punch.backup.lag") do
        loop do
          measure
          select
          when @stop.receive?
            break
          when timeout(INTERVAL)
          end
        end
      end
      spawn(name: "punch.backup.encryption") do
        loop do
          result = check_encryption
          select
          when @stop.receive?
            break
          when timeout(result.is_a?(Encryption::Unknown) ? RETRY : RECHECK)
          end
        end
      end
    end

    def stop : Nil
      @stop.close
    end

    # `nil` when healthy, else why not: a file without a replica (outside
    # development and test), or a bucket not known to encrypt.
    def health : String?
      if required? && !missing.empty?
        files = missing.join(", ") { |name| "#{name}.db" }
        return "backup: no replica for #{files}: set PUNCH_BACKUP_URL, or exempt them with PUNCH_BACKUP_EXEMPT"
      end

      case result = encryption
      when Encryption::Unencrypted
        "backup: the bucket has no default encryption; turn it on (Litestream does not encrypt), or set PUNCH_BACKUP_ENCRYPTION=provider if the provider encrypts every object"
      when Encryption::Unknown
        "backup: cannot confirm that the bucket encrypts (#{result.reason}); set PUNCH_BACKUP_ENCRYPTION=provider if the provider encrypts every object"
      end
    end

    # The last answer about the bucket's encryption; `nil` before the first.
    def encryption : Encryption::Result?
      @lock.synchronize { @encryption }
    end

    # The lag of each replicated file as last measured.
    def lags : Hash(String, Time::Span)
      @lock.synchronize { @lags.dup }
    end

    # Asks the bucket and keeps the answer; reports one that is not
    # `Encrypted` (or not asked) as a `NotEncrypted` error.
    def check_encryption : Encryption::Result
      result = (env = @env) ? Encryption.check(litestream.config, env) : Encryption.check(litestream.config)
      previous = @lock.synchronize { @encryption.tap { @encryption = result } }
      if result.is_a?(Encryption::Unencrypted | Encryption::Unknown) && previous.class != result.class
        reason = result.is_a?(Encryption::Unknown) ? result.reason : "no default encryption"
        @tracer.report(NotEncrypted.new("#{litestream.config.display_url}: #{reason}"), "backup")
      end
      result
    end

    # Measures every replicated file's lag now.
    def measure(now : Time = Time.utc) : Hash(String, Time::Span)
      replicas = litestream.replicas
      lags = litestream.names.to_h do |name|
        path = litestream.database_path(name)
        if synced = replicas.try(&.find { |replica| replica.path == path }).try(&.last_sync_at)
          @lock.synchronize { @synced[name] = synced }
        end
        synced = @lock.synchronize { @synced[name]? }
        {name, Monitor.lag(Monitor.changed_at(path), synced, @since, now)}
      end
      lagging = lags.select { |_, lag| lag > LAGGING }.keys.to_set
      fresh = @lock.synchronize do
        @lags = lags
        (lagging - @lagging).tap { @lagging = lagging }
      end
      fresh.each do |name|
        @tracer.report(Lagging.new("#{name}.db has not reached its replica for #{lags[name].total_seconds.to_i} s#{replicas ? "" : " (no Litestream answers on #{litestream.socket_path})"}"), "backup")
      end
      lags
    end

    # How long ago the restore check last passed (`verification.json`),
    # or since this monitor started when none has.
    def verification_age(now : Time = Time.utc) : Time::Span
      since = VerificationStatus.read(litestream.storage).try(&.last_passed_at) || @since
      Math.max(now - since, Time::Span.zero)
    end

    # When *path* last changed: its WAL file, else the file itself.
    def self.changed_at(path : String) : Time?
      File.info?("#{path}-wal").try(&.modification_time) || File.info?(path).try(&.modification_time)
    end

    # The lag of a file that changed at *changed_at*, whose replica last
    # synced at *synced_at*, measured by a process started at *since*.
    def self.lag(changed_at : Time?, synced_at : Time?, since : Time, now : Time) : Time::Span
      return Time::Span.zero if changed_at.nil? || (synced_at && changed_at <= synced_at)

      start = synced_at || Math.max(since, changed_at)
      Math.max(now - start, Time::Span.zero)
    end

    # Registers `punch.backup.lag`, `punch.backup.verification.age`, and
    # the sidecar's restarts with *registry* (`docs/metrics.md`).
    def observe(registry : Metrics::Registry = Metrics.registry) : Nil
      return if litestream.names.empty?

      registry.observe("punch.backup.lag", :gauge, "s",
        "Time since the oldest change not yet in the replica; 0 when the replica has everything") do |recorder|
        lags.each do |name, lag|
          recorder.record(lag.total_seconds, Metrics::Attributes{"db.namespace" => name})
        end
      end
      registry.observe("punch.backup.verification.age", :gauge, "s",
        "Time since the restore check last passed; before the first, since this process started") do |recorder|
        recorder.record(verification_age.total_seconds, Metrics::Attributes.new)
      end
      if sidecar = @sidecar
        registry.observe("punch.backup.sidecar.restarts", :counter, "{restart}",
          "Times Litestream exited unasked and was started again by this process") do |recorder|
          recorder.record(sidecar.restarts, Metrics::Attributes.new)
        end
      end
    end
  end
end
