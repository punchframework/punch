module Punch::CLI::Commands
  # Serves the application it is compiled into: opens `primary.db`,
  # `cache.db`, `queue.db`, and `ops.db` in `PUNCH_STORAGE`, routes every operation,
  # runs job workers unless `PUNCH_JOBS=off`, and runs until
  # SIGINT or SIGTERM has drained it (`docs/http.md`). Settings come from the
  # environment (`punch config`); the app's credentials are checked before
  # anything opens (`punch creds:check`). Wide events go to stdout, so there is no
  # JSON mode.
  class Serve < Command
    command "serve", "Run the HTTP server with the settings from the environment (see punch config)"

    def self.json? : Bool
      false
    end

    struct Stopped
      include Report

      def to_text(io : IO) : Nil
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { }
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      settings = Config.settings(require_env: true)
      return settings if settings.is_a?(Failure)

      # The default context starts with one thread; it serves requests, and
      # the reader pool gets one connection per thread.
      booted = Serve.boot(settings) { Fiber::ExecutionContext.default.resize(settings.threads) }
      return booted if booted.is_a?(Failure)

      databases, queue = booted
      sink = Serve.ops_sink(settings)
      tracer = settings.tracer(sink ? [sink] of Punch::Trace::EventSink : [] of Punch::Trace::EventSink)
      router = Punch::Routing::Router.new(databases.primary, openapi: Punch.openapi_document)
      server = Punch::HTTP::Server.new(settings.http, tracer) { |context| router.call(context) }
      # Live pages' streams close, so browsers reconnect to the next process.
      server.on_drain("live") { Punch::Live.hub.close }
      # Streams leave a quarter of this server's connections to other requests.
      Punch::Live.max_streams = {Punch::Live.max_streams, server.config.max_connections * 3 // 4}.min
      # Background work waits while a restore waits for confirmation.
      hold = Punch::Backup::Recovery::Hold.new(settings.storage)
      hold.observe
      server.on_shutdown("recovery") { hold.stop }
      worker : Punch::Job::Queue::Worker? = nil
      if settings.jobs?
        built = Serve.worker(queue, databases, tracer, settings, "serve")
        return built if built.is_a?(Failure)

        worker = jobs = built
        server.health_check("jobs") { hold.held? || jobs.alive? ? nil : "jobs: dispatcher stopped" }
        # Before the databases close: running jobs finish or go back.
        server.on_shutdown("jobs") { jobs.stop }
      end
      relay = Punch::Job::Outbox::Relay.new(databases.primary, queue)
      hold.start do
        worker.try(&.start)
        relay.start_when_used
      end
      # After the last requests, before the databases close.
      server.on_shutdown("outbox") { relay.stop }
      # The last wide events reach ops.db before it closes.
      server.on_shutdown("ops") { sink.close } if sink
      # The last values, before the databases close.
      if metrics = settings.metric_exporter
        metrics.start
        server.on_shutdown("metrics") { metrics.stop }
      end
      # Bans are kept in cache.db; the last ones are written before it closes.
      server.guard.start(databases["cache"])
      server.guard.observe
      Punch::HTTP::Probes.attach(server.guard)
      server.on_shutdown("probes") { server.guard.stop }
      databases.attach(server)
      sidecar, monitor, heartbeat = Serve.backup(settings, databases, tracer)
      Serve.attach(server, sidecar, monitor, heartbeat)
      begin
        server.run
      rescue ex : Socket::BindError
        hold.stop
        worker.try(&.stop)
        relay.stop
        tracer.close
        server.guard.stop
        heartbeat.try(&.stop)
        databases.close
        monitor.stop
        sidecar.try(&.stop)
        return Failure.new("bind_failed", "Cannot listen on #{settings.host}:#{settings.port}: #{ex.message}")
      end
      Stopped.new
    end

    # The routes and assets that the probe patterns would answer as probes
    # (`Punch::HTTP::Probes.patterns`, set in `app/setup.cr`): the app
    # could not serve them, so it does not start.
    def self.probe_failure(settings : Punch::AppConfig) : Failure?
      return unless settings.probes?

      paths = Punch::Routing.routes.map(&.template) + Punch::Assets.table.by_url.keys
      conflicts = Punch::HTTP::Probes.conflicts(paths)
      return if conflicts.empty?

      Failure.new("probe_patterns", "These routes and assets look like what scanners ask for, so they would be answered 404 and their visitors banned: #{conflicts.join(", ")}. " \
                                    "Rename them, or take the pattern out in app/setup.cr: Punch::HTTP::Probes.patterns = Punch::HTTP::Probes::Patterns.default.without(...) (lib/punch/docs/http.md).")
    end

    # What `serve` and `jobs` do before they start: check that Litestream
    # can run when files are to be replicated, check the credentials,
    # apply the app's pending migrations (`PUNCH_MIGRATE`), open `primary.db`, `cache.db`, `queue.db`, and (unless `PUNCH_OPS=off`)
    # `ops.db` in `PUNCH_STORAGE`, check the primary's Punch tables, and
    # attach the cache, the queue, and the ops store. Refuses while a
    # restore replaces the files, and after one that stopped halfway.
    # *before_open* runs just before the databases open.
    def self.boot(settings : Punch::AppConfig, & : ->) : {Punch::Databases, Punch::Job::Queue} | Failure
      if failure = startup_failure(settings)
        return failure
      end

      Punch.public_url = settings.public_url
      yield
      Dir.mkdir_p(settings.storage, 0o700)
      Punch::Backup.storage = settings.storage
      if failure = restore_failure(settings)
        return failure
      end
      if failure = migrate(settings)
        return failure
      end

      databases = Punch::Databases.open(settings.storage, files(settings))
      databases.observe
      Punch::Caches.enabled = settings.cache?
      begin
        Punch::Caches.attach(Punch::Caches::Durable.new(databases["cache"], settings.cache_bytes))
      rescue ex : Punch::Database::Error
        databases.close
        return Failure.new("cache_database", "cache.db cannot be used: #{ex.message}")
      end
      if failure = schema_failure(databases)
        databases.close
        return failure
      end
      # The operations of each role, as this binary's code defines them.
      Punch::Roles.sync(databases.primary) if Punch::Roles.used?
      Punch::IdempotencyKeys.retention = settings.idempotency_retention
      Punch::Webhook.retention = settings.webhook_retention
      queue = begin
        Punch::Job::Queue.new(databases["queue"])
      rescue ex : Punch::Job::Queue::Error | Punch::Database::Error
        databases.close
        return Failure.new("queue_database", "queue.db cannot be used: #{ex.message}")
      end
      Punch::Job::Queue.attach(queue)
      Punch::Job::Queue.retention = settings.job_retention
      if failure = attach_ops(databases, settings)
        databases.close
        return failure
      end
      {databases, queue}
    rescue ex : Punch::Database::FilesystemError
      Failure.new("filesystem_refused", ex.message || "filesystem refused")
    end

    # Why the process cannot start as configured, before anything opens.
    private def self.startup_failure(settings : Punch::AppConfig) : Failure?
      probe_failure(settings) || backup_failure(settings) || credentials_failure(settings)
    end

    # The problems of the app's credentials, if it declares any.
    private def self.credentials_failure(settings : Punch::AppConfig) : Failure?
      if (credentials = Punch::Credentials.boot(settings.environment)) && !credentials.problems.empty?
        CredsCheck.failure(credentials)
      end
    end

    # Why the files cannot be opened because of a restore: one replaces
    # them now (it holds `punch.lock` exclusively, which this takes shared
    # for the life of the process), or one stopped halfway.
    private def self.restore_failure(settings : Punch::AppConfig) : Failure?
      unless Punch::Backup::Recovery.share(settings.storage)
        return Failure.new("restore_running", "A restore is replacing the files in #{settings.storage} (punch restore); start once it has finished.")
      end

      Punch::Backup::Recovery.incomplete(settings.storage).try { |problem| Failure.new("restore_incomplete", problem) }
    end

    # Applies the app's pending migrations (`Punch.migrations`) to the
    # primary before anything else opens it, or with `PUNCH_MIGRATE=off`
    # refuses while any are pending. On a connection of its own and without
    # the collation check, which a pending `REINDEX` migration resolves. A
    # process that migrates at the same time, such as `jobs` next to
    # `serve`, applies each migration once with it.
    private def self.migrate(settings : Punch::AppConfig) : Failure?
      migrations = Punch::Migrations.app || return
      config = Punch::Database::Config.new(readers: 1, check_collations: false)
      database = Punch::Database.open(settings.primary_database, name: "primary", config: config)
      begin
        migrator = Punch::Migrations::Migrator.new(database, migrations)
        unless settings.migrate?
          pending = migrator.pending
          return if pending.empty?

          return Failure.new("migrations_pending", "#{settings.primary_database} lacks #{pending.size} migration(s) of this binary: #{pending.join(", ", &.file_name)}. " \
                                                   "Run db:migrate first, or start with PUNCH_MIGRATE=on.")
        end
        migrator.migrate.each { |migration| MigrationLog.info { "applied #{migration.file_name}" } }
        nil
      ensure
        database.close
      end
    rescue ex : Punch::Migrations::Error | Punch::Database::Error
      MigrationCommand.failure(ex)
    end

    MigrationLog = ::Log.for("punch.migrations")

    # What the primary database lacks of Punch's tables that this binary
    # uses (did `db:migrate` run?), or `nil`.
    private def self.schema_failure(databases : Punch::Databases) : Failure?
      if Punch::Auth.used? && !(problems = Punch::Auth::Schema.problems(databases.primary)).empty?
        return Failure.new("auth_schema", "The primary database lacks what sessions and tokens need (did db:migrate run?):\n  #{problems.join("\n  ")}")
      end
      if Punch::Roles.used? && !(lacking_roles = Punch::Roles::Schema.problems(databases.primary)).empty?
        return Failure.new("roles_schema", "The primary database lacks what the app's roles need (did db:migrate run?):\n  #{lacking_roles.join("\n  ")}")
      end
      if failure = job_schema_failure(databases)
        return failure
      end
      if Punch::Upload.used? && !(unready = Punch::Upload.table_problems(databases.primary)).empty?
        return Failure.new("uploads_schema", "The primary database lacks the table for uploads, which the app's kinds of upload need (did db:migrate run?):\n  #{unready.join("\n  ")}")
      end
      if Punch::Webhook.used? && !(absent = Punch::Webhook::Invocations.problems(databases.primary)).empty?
        return Failure.new("webhooks_schema", "The primary database lacks the table for inbound webhooks, which the app's providers need (did db:migrate run?):\n  #{absent.join("\n  ")}")
      end

      if Punch::IdempotencyKeys.used? && !(missing = Punch::IdempotencyKeys.problems(databases.primary)).empty?
        Failure.new("idempotency_schema", "The primary database lacks the table for idempotency keys, which Commands that know their caller accept (did db:migrate run?):\n  #{missing.join("\n  ")}")
      end
    end

    # What the primary database lacks of the jobs' tables: the outbox and
    # the progress of jobs with steps.
    private def self.job_schema_failure(databases : Punch::Databases) : Failure?
      if Punch::Job::Outbox.used? && !(lacking = Punch::Job::Outbox.problems(databases.primary)).empty?
        return Failure.new("outbox_schema", "The primary database lacks the outbox that enqueues from Commands need (did db:migrate run?):\n  #{lacking.join("\n  ")}")
      end
      unless (unsaved = Punch::Job::Steps::Progress.problems(databases.primary)).empty?
        Failure.new("job_progress_schema", "The primary database lacks the table jobs with steps save their progress in, which every app has (did db:migrate run?):\n  #{unsaved.join("\n  ")}")
      end
    end

    # Why the files cannot be replicated as configured: Litestream is
    # missing, or the storage path is too long for its socket.
    def self.backup_failure(settings : Punch::AppConfig) : Failure?
      litestream = Punch::Backup::Litestream.new(settings.backup, settings.storage, files(settings))
      return if litestream.names.empty?

      litestream.problem.try { |problem| Failure.new("backup_unavailable", "Cannot replicate #{litestream.names.join(", ") { |name| "#{name}.db" }}: #{problem}") }
    end

    # Starts the Litestream sidecar, when files are replicated, the
    # monitor of the replicas, both with their metrics, and the heartbeat
    # that keeps quiet files' replicas current (`docs/backup.md`).
    def self.backup(settings : Punch::AppConfig, databases : Punch::Databases,
                    tracer : Punch::Trace::Tracer) : {Punch::Backup::Sidecar?, Punch::Backup::Monitor, Punch::Backup::Heartbeat?}
      litestream = Punch::Backup::Litestream.new(settings.backup, settings.storage, databases.names)
      sidecar = litestream.names.empty? ? nil : Punch::Backup::Sidecar.new(litestream, tracer)
      monitor = Punch::Backup::Monitor.new(litestream, databases.names, settings.environment, tracer, sidecar: sidecar)
      heartbeat = litestream.names.empty? ? nil : Punch::Backup::Heartbeat.new(litestream.names.map { |name| databases[name] }, tracer)
      monitor.observe
      Punch::Backup.monitor = monitor
      # For the restore check (`Punch::Backup::Verify`).
      Punch::Backup.current = litestream unless litestream.names.empty?
      sidecar.try(&.start)
      monitor.start
      heartbeat.try(&.start)
      {sidecar, monitor, heartbeat}
    end

    # The backup's health check, and stopping it after the databases close,
    # so Litestream syncs their last writes.
    def self.attach(server : Punch::HTTP::Server, sidecar : Punch::Backup::Sidecar?, monitor : Punch::Backup::Monitor,
                    heartbeat : Punch::Backup::Heartbeat?) : Nil
      server.health_check("backup") { monitor.health }
      server.on_shutdown("backup") do
        heartbeat.try(&.stop)
        monitor.stop
        sidecar.try(&.stop)
      end
    end

    # The database files a process opens.
    private def self.files(settings : Punch::AppConfig) : Array(String)
      settings.ops? ? %w[primary cache queue ops] : %w[primary cache queue]
    end

    # Attaches `ops.db` unless `PUNCH_OPS=off`, or says why it cannot.
    private def self.attach_ops(databases : Punch::Databases, settings : Punch::AppConfig) : Failure?
      return unless settings.ops?

      Punch::Ops.attach(Punch::Ops::Store.new(databases["ops"]))
      Punch::Ops.retention = settings.ops_retention
      Punch::Ops.slow = settings.ops_slow_ms.milliseconds
      Punch::Ops.development = settings.environment == "development"
      nil
    rescue ex : Punch::Ops::Error | Punch::Database::Error
      Failure.new("ops_database", "ops.db cannot be used: #{ex.message}")
    end

    # The sink that records wide events in the attached `ops.db`, or `nil`
    # with `PUNCH_OPS=off`.
    def self.ops_sink(settings : Punch::AppConfig) : Punch::Ops::Sink?
      store = Punch::Ops.current? || return
      Punch::Ops::Sink.new(store, sample: settings.ops_sample_percent / 100.0)
    end

    # The job workers of this process, or a failure naming the recurring
    # job whose schedule does not parse (the databases are closed then).
    def self.worker(queue : Punch::Job::Queue, databases : Punch::Databases, tracer : Punch::Trace::Tracer,
                    settings : Punch::AppConfig, kind : String) : Punch::Job::Queue::Worker | Failure
      Punch::Job::Queue::Worker.new(queue, databases.primary, tracer, settings.worker, kind: kind)
    rescue ex : ArgumentError
      databases.close
      Failure.new("invalid_schedule", ex.message || "invalid schedule")
    end
  end
end
