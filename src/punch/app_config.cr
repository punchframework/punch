module Punch
  # The settings of an application process, read from the environment at
  # boot. Credentials, the environment first and then the encrypted file,
  # are checked by `Punch::Credentials`. Every value is checked before
  # anything starts, and every problem is reported at once.
  #
  # | Variable | Default | |
  # |---|---|---|
  # | `PUNCH_ENV` | `development`, except for `serve` and `jobs`, which refuse to start without it | Selects the credentials file and key (`config/credentials/<env>.yml.enc`); `development` also opens the ops console to every signed-in user unless it names a policy. `punch dev` sets it |
  # | `PUNCH_STORAGE` | `storage` | Directory of the database files (`primary.db`, …). Local disk only |
  # | `PUNCH_HOST` | `127.0.0.1` | Address the server binds; `0.0.0.0` in a container |
  # | `PUNCH_PORT` | `3000` | |
  # | `PUNCH_PUBLIC_URL` | `http://<host>:<port>` in development and test | Where people reach the app (`https://invoices.example.org`), the base of links in mail; required in other environments |
  # | `PUNCH_TRUSTED_PROXIES` | none | Comma-separated addresses or CIDR ranges whose forwarded headers are believed |
  # | `PUNCH_DRAIN_DELAY_SECONDS` | `0` | How long shutdown keeps accepting after `/up` turns 503, so a proxy that polls `/up` stops sending first (Caddy); 0 behind kamal-proxy |
  # | `PUNCH_SHUTDOWN_TIMEOUT_SECONDS` | `25` | How long shutdown waits for requests in progress; below the time the supervisor gives before SIGKILL |
  # | `PUNCH_MIGRATE` | `on` | `serve` and `jobs` apply the app's pending migrations at boot (`Punch.migrations`); `off` refuses to start while any are pending |
  # | `PUNCH_TRUSTED_ORIGINS` | none | Comma-separated origins (`https://admin.example.com`) whose pages may send Commands; the app's own origin needs none |
  # | `PUNCH_THREADS` | `CRYSTAL_WORKERS`, else the CPU count | Threads of the default execution context, which serves requests; one read connection each |
  # | `PUNCH_TRACE` | `json` | Wide events as JSON lines on stdout; `console` prints each trace as a tree on stderr, for development; `off` |
  # | `PUNCH_TRACE_SAMPLE_PERCENT` | `100` | Share of traces whose spans are recorded and exported over OTLP; wide events are written whatever it is |
  # | `OTEL_EXPORTER_OTLP_ENDPOINT` and the other `OTEL_*` | none | Export of traces and metrics over OTLP/HTTP (`Punch::OTLP::Config`) |
  # | `PUNCH_BACKUP_URL` and the other `PUNCH_BACKUP_*`, `PUNCH_LITESTREAM` | none | Replication of `primary.db`, `queue.db`, and `ops.db` with Litestream (`Punch::Backup::Config`) |
  # | `PUNCH_CACHE` | `on` | `off` makes every cache fetch compute, to check that the app is correct with an empty cache |
  # | `PUNCH_CACHE_MB` | `256` | Size cap of `cache.db` in MiB |
  # | `PUNCH_JOBS` | `on` | `off` runs no job workers in `serve`, for a separate `jobs` process |
  # | `PUNCH_JOB_THREADS` | `2` | Threads of the job workers' execution context |
  # | `PUNCH_JOB_CONCURRENCY` | `10` | Jobs running at once in one process |
  # | `PUNCH_JOB_QUEUES` | all | Comma-separated queues this process claims from |
  # | `PUNCH_JOB_RETENTION_HOURS` | `72` | How long finished jobs are kept |
  # | `PUNCH_OPS` | `on` | `off` records nothing in `ops.db` (errors, job runs, events for the ops console) |
  # | `PUNCH_OPS_SAMPLE_PERCENT` | `100` | Share of traces whose successful job runs and committed events `ops.db` keeps; errors and failures are always kept |
  # | `PUNCH_OPS_RETENTION_DAYS` | `14` | How long `ops.db` keeps job runs, occurrences, and events, and resolved errors after they were last seen |
  # | `PUNCH_OPS_SLOW_MS` | `500` | Successful requests taking at least this long keep their wide event in `ops.db`, for the console's slowest requests |
  # | `PUNCH_IDEMPOTENCY_RETENTION_HOURS` | `24` | How long a Command's answer under an idempotency key is replayed; at least 24, which `openapi.json` promises |
  # | `PUNCH_WEBHOOK_RETENTION_DAYS` | `30` | How long processed, ignored, and rejected inbound webhooks are kept |
  # | `PUNCH_PROBES` | `on` | `off` lets requests for paths only scanners ask for through to the router, and bans nobody (`docs/http.md`, "Probes and bans") |
  # | `PUNCH_PROBE_BAN_AFTER` | `2` | Probes from one address within the window that ban it; `0` never bans |
  # | `PUNCH_PROBE_WINDOW_MINUTES` | `10` | The window those probes count in |
  # | `PUNCH_PROBE_BANS` | `1h,24h,7d` | How long the first, the second, … ban lasts; the last applies to every further one (`s`, `m`, `h`, `d`) |
  # | `PUNCH_PROBE_ALLOW` | none | Comma-separated addresses or CIDR ranges never banned, such as an office's network or a monitoring service |
  struct AppConfig
    enum Trace
      Json
      Console
      Off
    end

    VARIABLES = %w[PUNCH_ENV PUNCH_STORAGE PUNCH_HOST PUNCH_PORT PUNCH_PUBLIC_URL PUNCH_TRUSTED_PROXIES PUNCH_TRUSTED_ORIGINS
      PUNCH_DRAIN_DELAY_SECONDS PUNCH_SHUTDOWN_TIMEOUT_SECONDS PUNCH_MIGRATE PUNCH_THREADS PUNCH_TRACE PUNCH_TRACE_SAMPLE_PERCENT PUNCH_CACHE PUNCH_CACHE_MB
      PUNCH_JOBS PUNCH_JOB_THREADS PUNCH_JOB_CONCURRENCY PUNCH_JOB_QUEUES PUNCH_JOB_RETENTION_HOURS
      PUNCH_OPS PUNCH_OPS_SAMPLE_PERCENT PUNCH_OPS_RETENTION_DAYS PUNCH_OPS_SLOW_MS PUNCH_IDEMPOTENCY_RETENTION_HOURS
      PUNCH_WEBHOOK_RETENTION_DAYS PUNCH_PROBES PUNCH_PROBE_BAN_AFTER PUNCH_PROBE_WINDOW_MINUTES PUNCH_PROBE_BANS
      PUNCH_PROBE_ALLOW] + OTLP::Config::VARIABLES + Backup::Config::VARIABLES
    MAX_THREADS  =      1024
    MAX_CACHE_MB = 1_048_576

    getter environment : String
    getter storage : String
    getter host : String
    getter port : Int32
    # Without a trailing slash (`Punch.public_url`).
    getter public_url : String
    getter trusted_proxies : Array(String)
    getter trusted_origins : Array(String)
    getter drain_delay_seconds : Int32
    getter shutdown_timeout_seconds : Int32
    getter? migrate : Bool
    getter threads : Int32
    getter trace : Trace
    getter trace_sample_percent : Int32
    # Where traces and metrics are exported; `nil` for nowhere.
    getter otlp : OTLP::Config?
    getter backup : Backup::Config
    getter? cache : Bool
    getter cache_mb : Int32
    getter? jobs : Bool
    getter job_threads : Int32
    getter job_concurrency : Int32
    # `nil` for every queue.
    getter job_queues : Array(String)?
    getter job_retention_hours : Int32
    getter? ops : Bool
    getter ops_sample_percent : Int32
    getter ops_retention_days : Int32
    getter ops_slow_ms : Int32
    getter idempotency_retention_hours : Int32
    getter webhook_retention_days : Int32
    getter? probes : Bool
    getter probe_ban_after : Int32
    getter probe_window_minutes : Int32
    getter probe_bans : Array(Time::Span)
    getter probe_allow : Array(String)

    def initialize(*, @environment = "development", @storage = "storage", @host = "127.0.0.1", @port = 3000,
                   public_url : String? = nil, @trusted_proxies = [] of String, @trusted_origins = [] of String,
                   @drain_delay_seconds = 0, @shutdown_timeout_seconds = 25, @migrate = true, @threads = Fiber::ExecutionContext.default_workers_count, @trace = Trace::Json,
                   @trace_sample_percent = 100, @otlp : OTLP::Config? = nil, @backup : Backup::Config = Backup::Config.new,
                   @cache = true, @cache_mb = 256, @jobs = true, @job_threads = 2, @job_concurrency = 10,
                   @job_queues : Array(String)? = nil, @job_retention_hours = 72, @ops = true, @ops_sample_percent = 100,
                   @ops_retention_days = 14, @ops_slow_ms = 500, @idempotency_retention_hours = 24,
                   @webhook_retention_days = 30, @probes = true, @probe_ban_after = 2, @probe_window_minutes = 10,
                   @probe_bans = [1.hour, 24.hours, 7.days], @probe_allow = [] of String)
      @public_url = public_url || "http://#{@host}:#{@port}"
    end

    # The settings in *env* (`ENV`, or a Hash in specs), or every problem
    # with them. With *require_env*, as for a process that serves or runs
    # jobs, a missing `PUNCH_ENV` is a problem: read as development, it
    # would loosen what production keeps closed.
    def self.from(env = ENV, *, require_env : Bool = false) : AppConfig | Array(String)
      problems = [] of String
      environment = environment(env, require_env, problems)
      storage = env["PUNCH_STORAGE"]?.presence || "storage"
      host = env["PUNCH_HOST"]?.presence || "127.0.0.1"
      port = integer(env, "PUNCH_PORT", 1..65535, 3000, problems, "a port number")
      public_url = public_url(env, environment, problems)
      proxies = env["PUNCH_TRUSTED_PROXIES"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
      begin
        HTTP::TrustedProxies.parse(proxies)
      rescue ex : HTTP::TrustedProxies::Error
        problems << "PUNCH_TRUSTED_PROXIES: #{ex.message}"
      end
      origins = env["PUNCH_TRUSTED_ORIGINS"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
      begin
        HTTP::CrossOrigin.normalize(origins)
      rescue ex : ArgumentError
        problems << "PUNCH_TRUSTED_ORIGINS: #{ex.message}"
      end
      drain_delay_seconds = integer(env, "PUNCH_DRAIN_DELAY_SECONDS", 0..300, 0, problems, "a number of seconds")
      shutdown_timeout_seconds = integer(env, "PUNCH_SHUTDOWN_TIMEOUT_SECONDS", 1..3600, 25, problems, "a number of seconds")
      migrate = switch(env, "PUNCH_MIGRATE", problems)
      threads = integer(env, "PUNCH_THREADS", 1..MAX_THREADS, Fiber::ExecutionContext.default_workers_count, problems, "a number")
      trace = env["PUNCH_TRACE"]?.presence.try do |text|
        Trace.parse?(text) || (problems << "PUNCH_TRACE must be json, console, or off, got #{text.inspect}"; nil)
      end || Trace::Json
      trace_sample_percent = integer(env, "PUNCH_TRACE_SAMPLE_PERCENT", 0..100, 100, problems, "a percentage")
      otlp = OTLP::Config.from(env, environment, problems)
      backup = Backup::Config.from(env, problems)
      cache = switch(env, "PUNCH_CACHE", problems)
      cache_mb = integer(env, "PUNCH_CACHE_MB", 1..MAX_CACHE_MB, 256, problems, "a size in MiB")
      jobs = switch(env, "PUNCH_JOBS", problems)
      job_threads = integer(env, "PUNCH_JOB_THREADS", 1..MAX_THREADS, 2, problems, "a number")
      job_concurrency = integer(env, "PUNCH_JOB_CONCURRENCY", 1..10_000, 10, problems, "a number")
      job_queues = queues(env, problems)
      job_retention_hours = integer(env, "PUNCH_JOB_RETENTION_HOURS", 1..87_600, 72, problems, "a number of hours")
      ops = switch(env, "PUNCH_OPS", problems)
      ops_sample_percent = integer(env, "PUNCH_OPS_SAMPLE_PERCENT", 0..100, 100, problems, "a percentage")
      ops_retention_days = integer(env, "PUNCH_OPS_RETENTION_DAYS", 1..3650, 14, problems, "a number of days")
      ops_slow_ms = integer(env, "PUNCH_OPS_SLOW_MS", 1..600_000, 500, problems, "a number of milliseconds")
      idempotency_retention_hours = integer(env, "PUNCH_IDEMPOTENCY_RETENTION_HOURS", 24..8760, 24, problems, "a number of hours")
      webhook_retention_days = integer(env, "PUNCH_WEBHOOK_RETENTION_DAYS", 1..3650, 30, problems, "a number of days")
      probes, probe_ban_after, probe_window_minutes, probe_bans, probe_allow = probes(env, problems)
      return problems unless problems.empty?

      new(environment: environment, storage: storage, host: host, port: port, public_url: public_url, trusted_proxies: proxies, trusted_origins: origins,
        drain_delay_seconds: drain_delay_seconds, shutdown_timeout_seconds: shutdown_timeout_seconds, migrate: migrate, threads: threads, trace: trace,
        trace_sample_percent: trace_sample_percent, otlp: otlp, backup: backup,
        cache: cache, cache_mb: cache_mb, jobs: jobs, job_threads: job_threads, job_concurrency: job_concurrency, job_queues: job_queues,
        job_retention_hours: job_retention_hours, ops: ops, ops_sample_percent: ops_sample_percent, ops_retention_days: ops_retention_days,
        ops_slow_ms: ops_slow_ms,
        idempotency_retention_hours: idempotency_retention_hours, webhook_retention_days: webhook_retention_days,
        probes: probes, probe_ban_after: probe_ban_after, probe_window_minutes: probe_window_minutes, probe_bans: probe_bans,
        probe_allow: probe_allow)
    end

    # `PUNCH_PROBES` and the `PUNCH_PROBE_*` settings.
    private def self.probes(env, problems : Array(String)) : {Bool, Int32, Int32, Array(Time::Span), Array(String)}
      enabled = switch(env, "PUNCH_PROBES", problems)
      ban_after = integer(env, "PUNCH_PROBE_BAN_AFTER", 0..1000, 2, problems, "a number")
      window_minutes = integer(env, "PUNCH_PROBE_WINDOW_MINUTES", 1..10_080, 10, problems, "a number of minutes")
      bans = spans(env, "PUNCH_PROBE_BANS", problems) || [1.hour, 24.hours, 7.days]
      allow = env["PUNCH_PROBE_ALLOW"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
      begin
        HTTP::TrustedProxies.parse(allow, "allowed address")
      rescue ex : HTTP::TrustedProxies::Error
        problems << "PUNCH_PROBE_ALLOW: #{ex.message}"
      end
      {enabled, ban_after, window_minutes, bans, allow}
    end

    # The durations in *key* (`1h,24h,7d`), `nil` when unset: one to ten,
    # each from a minute to a year, in `s`, `m`, `h`, or `d`.
    private def self.spans(env, key : String, problems : Array(String)) : Array(Time::Span)?
      text = env[key]?.presence || return
      units = {"s" => 1.second, "m" => 1.minute, "h" => 1.hour, "d" => 1.day}
      spans = text.split(',').map(&.strip).map do |entry|
        number = entry[0...-1].to_i? if entry.size > 1
        unit = units[entry[-1..]?]? if number
        span = unit * number if unit && number
        span if span && 1.minute <= span <= 365.days
      end
      if spans.empty? || spans.size > 10 || spans.any?(Nil)
        problems << "#{key} must be one to ten durations from 1m to 365d, such as 1h,24h,7d, got #{text.inspect}"
        return
      end
      spans.compact
    end

    # `PUNCH_PUBLIC_URL` without its trailing slash: an `http` or `https`
    # origin, optionally with a path, no query or fragment. Required outside
    # development and test, where a default would put wrong links in mail.
    private def self.public_url(env, environment : String, problems : Array(String)) : String?
      text = env["PUNCH_PUBLIC_URL"]?.presence
      unless text
        # An invalid PUNCH_ENV is reported once, above.
        if !environment.in?("development", "test") && Credentials::ENVIRONMENT.matches?(environment)
          problems << "PUNCH_PUBLIC_URL must be set in #{environment}: where people reach the app, such as https://invoices.example.org (links in mail)"
        end
        return
      end
      uri = URI.parse(text) rescue nil
      if uri.nil? || !uri.scheme.in?("http", "https") || uri.host.presence.nil? || uri.query || uri.fragment || uri.user
        problems << "PUNCH_PUBLIC_URL must be an http or https URL without query or fragment, such as https://invoices.example.org, got #{Text.shown_url(text)}"
        return
      end
      text.rstrip('/')
    end

    # The queues in `PUNCH_JOB_QUEUES`; `nil` (every queue) when unset or `*`.
    private def self.queues(env, problems : Array(String)) : Array(String)?
      queues = env["PUNCH_JOB_QUEUES"]?.presence.try(&.split(',').map(&.strip).reject(&.empty?))
      return if queues.nil? || queues.empty? || queues == ["*"]

      queues.each do |queue|
        problems << "PUNCH_JOB_QUEUES: #{queue.inspect} is not a queue name (lowercase letters, digits, and _)" unless queue.matches?(/\A[a-z][a-z0-9_]{0,62}\z/)
      end
      queues
    end

    # `on` (the default when unset) or `off` in *key*.
    private def self.switch(env, key : String, problems : Array(String)) : Bool
      case text = env[key]?.presence
      when nil, "on" then true
      when "off"     then false
      else                problems << "#{key} must be on or off, got #{text.inspect}"; true
      end
    end

    # The integer in *key*, *default* when unset; a problem when it is not
    # a whole number in *range*.
    private def self.integer(env, key : String, range : Range(Int32, Int32), default : Int32, problems : Array(String), what : String) : Int32
      text = env[key]?.presence || return default
      value = text.to_i?
      return value if value && range.includes?(value)

      problems << "#{key} must be #{what} from #{range.begin} to #{range.end}, got #{text.inspect}"
      default
    end

    # `PUNCH_ENV`, development when it is missing and *required* is not set.
    private def self.environment(env, required : Bool, problems : Array(String)) : String
      if required && env["PUNCH_ENV"]?.presence.nil?
        problems << "PUNCH_ENV is not set: name the environment this process runs as (production in a deployment; punch dev sets development)"
      end
      environment = env["PUNCH_ENV"]?.presence || "development"
      unless Credentials::ENVIRONMENT.matches?(environment)
        problems << "PUNCH_ENV must be lowercase letters, digits, and _, got #{environment.inspect}"
      end
      environment
    end

    # The primary database file, the default for the `db:` commands.
    def primary_database : String
      File.join(storage, "primary.db")
    end

    # The size cap of `cache.db`.
    def cache_bytes : Int64
      cache_mb.to_i64 * 1024 * 1024
    end

    def http : HTTP::Config
      HTTP::Config.new(host: host, port: port, trusted_proxies: HTTP::TrustedProxies.parse(trusted_proxies),
        trusted_origins: trusted_origins, drain_delay: drain_delay_seconds.seconds,
        shutdown_timeout: shutdown_timeout_seconds.seconds, probes: probe_settings)
    end

    # How probes are answered and bans made (`HTTP::Probes`).
    def probe_settings : HTTP::Probes::Settings
      HTTP::Probes::Settings.new(enabled: probes?, ban_after: probe_ban_after, window: probe_window_minutes.minutes,
        bans: probe_bans, allow: HTTP::TrustedProxies.parse(probe_allow, "allowed address"))
    end

    # The settings of this process's job workers.
    def worker : Job::Queue::Worker::Config
      Job::Queue::Worker::Config.new(threads: job_threads, concurrency: job_concurrency, queues: job_queues)
    end

    def job_retention : Time::Span
      job_retention_hours.hours
    end

    def ops_retention : Time::Span
      ops_retention_days.days
    end

    def idempotency_retention : Time::Span
      idempotency_retention_hours.hours
    end

    def webhook_retention : Time::Span
      webhook_retention_days.days
    end

    # The tracer `PUNCH_TRACE` asks for, with *sinks* (the ops sink) next
    # to its own. With tracing off nothing reaches them either.
    # With an OTLP endpoint for traces, sampled traces go there too.
    def tracer(sinks : Array(Punch::Trace::EventSink) = [] of Punch::Trace::EventSink) : Punch::Trace::Tracer
      exporters = [] of Punch::Trace::Exporter
      exporters << Punch::Trace::ConsoleExporter.new if trace.console?
      otlp.try { |config| exporters << OTLP::TraceExporter.new(config) if config.traces }
      ratio = trace_sample_percent / 100.0

      case trace
      in .json?    then Punch::Trace::Tracer.new(exporters: exporters, events: [Punch::Trace::JSONEvents.new] of Punch::Trace::EventSink + sinks, sample_ratio: ratio)
      in .console? then Punch::Trace::Tracer.new(exporters: exporters, events: sinks, sample_ratio: ratio)
      in .off?     then Punch::Trace::Tracer.off
      end
    end

    # Sends `Punch::Metrics.registry` to the OTLP endpoint for metrics, if
    # there is one. Not started.
    def metric_exporter : OTLP::MetricExporter?
      otlp.try { |config| OTLP::MetricExporter.new(config) if config.metrics }
    end
  end
end
