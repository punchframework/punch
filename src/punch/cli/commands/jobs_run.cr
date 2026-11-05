module Punch::CLI::Commands
  # Runs the job workers of the application it is compiled into, with no
  # HTTP server: for a separate process next to `serve` started with
  # `PUNCH_JOBS=off` (docs/jobs.md). Same settings and databases as
  # `serve`; enqueues from `serve` reach it by polling. Stops on SIGINT or
  # SIGTERM like `serve`: running jobs finish or go back to the queue.
  class JobsRun < Command
    command "jobs", "Run the job workers without the HTTP server, as a separate process (see PUNCH_JOBS)"

    def self.json? : Bool
      false
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      settings = Config.settings(require_env: true)
      return settings if settings.is_a?(Failure)

      booted = Serve.boot(settings) { }
      return booted if booted.is_a?(Failure)

      databases, queue = booted
      sink = Serve.ops_sink(settings)
      tracer = settings.tracer(sink ? [sink] of Punch::Trace::EventSink : [] of Punch::Trace::EventSink)
      worker = Serve.worker(queue, databases, tracer, settings, "jobs")
      return worker if worker.is_a?(Failure)

      stop = Channel(Nil).new(2)
      {Signal::INT, Signal::TERM}.each do |signal|
        signal.trap { stop.send(nil) rescue nil }
      end
      relay = Punch::Job::Outbox::Relay.new(databases.primary, queue)
      # Background work waits while a restore waits for confirmation.
      hold = Punch::Backup::Recovery::Hold.new(settings.storage)
      hold.observe
      hold.start do
        relay.start_when_used
        worker.start
      end
      metrics = settings.metric_exporter
      metrics.try(&.start)
      sidecar, monitor, heartbeat = Serve.backup(settings, databases, tracer)
      Log.info { "jobs: #{worker.process_id} claiming from #{settings.job_queues.try(&.join(", ")) || "every queue"}" }
      stop.receive
      Log.info { "jobs: stopping" }
      hold.stop
      worker.stop
      relay.stop
      metrics.try(&.stop)
      tracer.close
      heartbeat.try(&.stop)
      databases.close
      # After the databases close, so Litestream syncs their last writes.
      monitor.stop
      sidecar.try(&.stop)
      Serve::Stopped.new
    end

    Log = ::Log.for("punch.jobs")
  end
end
