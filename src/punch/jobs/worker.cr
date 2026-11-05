module Punch
  class Job::Queue
    # Runs one claimed job and records how it ended: the job's trace and
    # wide event (continuing the trace that enqueued it), the outcome in
    # `queue.db`. Shared by the worker and `Punch::Spec.perform_jobs`.
    #
    # *stopping* tells a job with steps to stop between calls; a spec's
    # *interrupt_every* stops it after every so many saves.
    def self.perform(job : Claimed, queue : Job::Queue, database : Database, process : String, tracer : Trace::Tracer,
                     stopping : Proc(Bool) = -> { false }, interrupt_every : Int32? = nil) : Outcome
      span = tracer.start("job #{job.type}", :consumer, job.traceparent.try { |header| Trace::SpanContext.parse?(header) })
      begin
        if span.recording?
          span.set("messaging.system", "punch")
          span.set("messaging.operation.type", "process")
          span.set("messaging.destination.name", job.queue)
          span.set("messaging.message.id", job.id.to_s)
          span.set("punch.job.type", job.type)
          span.set("punch.job.attempt", job.attempts)
          span.set("punch.job.latency_ms", (Time.utc - {job.run_at, job.enqueued_at}.max).total_milliseconds.round(3))
        end
        run = Job::Steps.names.has_key?(job.type) ? Job::Steps::Run.new(job.key, job.type, stopping, interrupt_every) : nil
        context = Job::Context.new(database, queue, job.id, job.attempts, job.max_attempts, job.queue, job.key, run)
        outcome = begin
          ran = Trace.with(span) do
            if runner = Registry.runners[job.type]?
              runner.call(job.version, job.payload, context)
            else
              Registry::Unreadable.new("#{job.type} is not a job this binary knows")
            end
          end

          case ran
          in Nil then queue.finish(job, process)
          in Job::Retry
            span.error(ran.reason)
            queue.retry(job, process, ran.reason, ran.after)
          in Job::Discard
            span.set("punch.job.discarded", ran.reason) if span.recording?
            queue.discard(job, process, ran.reason)
          in Job::Steps::Pause
            span.set("punch.job.paused", ran.reason) if span.recording?
            queue.pause(job, process, ran.run_at)
          in Registry::Unreadable
            # Parked, not failed: a binary that reads it can run it. Logged
            # as an error, for the alert.
            span.error(ran.error)
            span.set("punch.job.version", job.version) if span.recording?
            Log.error { "job #{job.id} parked as incompatible: #{ran.error}" }
            queue.park(job, process, ran.error)
          end
        rescue ex
          span.error(ex)
          Log.error(exception: ex) { "job #{job.type} #{job.id} raised (attempt #{job.attempts} of #{job.max_attempts})" }
          queue.retry(job, process, describe(ex))
        end
        span.set("punch.job.outcome", outcome.to_s.downcase) if span.recording?
        Log.warn { "job #{job.id} (#{job.type}) was released before it finished; its result is not recorded" } if outcome.lost?
        outcome
      ensure
        span.finish
      end
    end

    # The workers of one process: a dispatcher fiber that claims due jobs
    # and one fiber per running job, all in an execution context of their
    # own, so jobs do not take threads from requests.
    #
    # Enqueues in this process wake the dispatcher at once
    # (`Job::Queue#on_enqueue`); jobs enqueued by another process are found by
    # polling. A heartbeat marks the process alive; each heartbeat also
    # hands back jobs of processes that stopped beating.
    class Worker
      struct Config
        # Threads of the workers' execution context.
        getter threads : Int32
        # Jobs running at once.
        getter concurrency : Int32
        # The queues to claim from; every queue when `nil`.
        getter queues : Array(String)?
        # How often to look for work enqueued by other processes, and for
        # jobs that have come due.
        getter poll_interval : Time::Span
        getter heartbeat_interval : Time::Span
        # A process whose heartbeat is this old counts as gone.
        getter stale_after : Time::Span
        # How long `stop` waits for running jobs before handing them back.
        getter shutdown_timeout : Time::Span

        def initialize(*, @threads : Int32 = 2, @concurrency : Int32 = 10, @queues : Array(String)? = nil,
                       @poll_interval : Time::Span = 1.second, @heartbeat_interval : Time::Span = 10.seconds,
                       @stale_after : Time::Span = 1.minute, @shutdown_timeout : Time::Span = 25.seconds)
          raise ArgumentError.new("threads must be at least 1") if @threads < 1
          raise ArgumentError.new("concurrency must be at least 1") if @concurrency < 1
          raise ArgumentError.new("stale_after must exceed the heartbeat interval") unless @stale_after > @heartbeat_interval
          @queues.try &.each { |queue| Job::Queue.check_name(queue) }
        end
      end

      getter queue : Job::Queue
      getter config : Config
      # Unique per process start: host, PID, and a random part.
      getter process_id : String

      @running = {} of Int64 => Claimed
      @running_lock = Mutex.new
      @wake = Channel(Nil).new(1)
      @stopping = Atomic(Bool).new(false)
      @started = false
      @dispatcher_done = Channel(Nil).new(1)
      @dispatcher_exited = Atomic(Bool).new(false)
      @heartbeat_stop = Channel(Nil).new(1)

      # *context* defaults to a new parallel context with the configured
      # threads; specs share one.
      # Recurring jobs (`Punch::Job::Recurring`) are enqueued by this process
      # too, unless *recurring* is false. Building their schedules raises
      # `ArgumentError` for a cron expression that does not parse.
      def initialize(@queue : Job::Queue, @database : Database, @tracer : Trace::Tracer, @config : Config = Config.new,
                     *, @kind : String = "serve", context : Fiber::ExecutionContext? = nil, recurring : Bool = true)
        @process_id = "#{System.hostname}:#{::Process.pid}:#{Random::Secure.hex(4)}"
        @scheduler = recurring ? Scheduler.new(@queue) : nil
        @context = context || Fiber::ExecutionContext::Parallel.new("punch-jobs", @config.threads)
      end

      # Registers the process and starts claiming.
      def start : Nil
        raise Error.new("worker started twice") if @started
        @started = true
        @queue.heartbeat(@process_id, @kind, @config.queues)
        @queue.on_enqueue { wake }
        @context.spawn(name: "punch-jobs-dispatcher") { dispatch }
        @context.spawn(name: "punch-jobs-heartbeat") { beat }
        @scheduler.try(&.start(@context))
      end

      # Stops claiming, waits up to the shutdown timeout for running jobs,
      # hands the rest back to the queue, and deregisters. Idempotent.
      def stop : Nil
        return unless @started
        return if @stopping.swap(true)

        @scheduler.try(&.stop)
        wake
        @dispatcher_done.receive
        deadline = Time.instant + @config.shutdown_timeout
        until running.empty? || Time.instant >= deadline
          sleep 10.milliseconds
        end
        unless (left = running).empty?
          released = @queue.release(left.map(&.id), @process_id)
          Log.warn { "stopped with #{left.size} job(s) still running; #{released} handed back to the queue" }
        end
        @heartbeat_stop.send(nil)
        @queue.deregister(@process_id)
      end

      # Whether the dispatcher is claiming, for `/up`.
      def alive? : Bool
        @started && !@stopping.get && !@dispatcher_exited.get
      end

      # Jobs this process is running now.
      def running : Array(Claimed)
        @running_lock.synchronize { @running.values }
      end

      # Makes the dispatcher look for work now.
      def wake : Nil
        select
        when @wake.send(nil)
        else
        end
      end

      private def dispatch : Nil
        until @stopping.get
          free = @config.concurrency - @running_lock.synchronize { @running.size }
          claimed = free > 0 ? claim(free) : [] of Claimed
          claimed.each do |job|
            @running_lock.synchronize { @running[job.id] = job }
            @context.spawn(name: "punch-job") { run(job) }
          end
          next if free > 0 && claimed.size == free
          wait(free > 0 ? until_due : @config.poll_interval)
        end
      ensure
        @dispatcher_exited.set(true)
        @dispatcher_done.send(nil)
      end

      private def claim(free : Int32) : Array(Claimed)
        @queue.claim(@process_id, free, Registry.types, @config.queues)
      rescue ex
        Log.error(exception: ex) { "claiming jobs failed" }
        @tracer.report(ex, "jobs: claiming")
        [] of Claimed
      end

      # How long until the next waiting job is due, at most the poll
      # interval.
      private def until_due : Time::Span
        due = @queue.next_due(Registry.types, @config.queues)
        return @config.poll_interval unless due

        (due - Time.utc).clamp(1.millisecond, @config.poll_interval)
      rescue ex
        Log.error(exception: ex) { "reading the next due job failed" }
        @tracer.report(ex, "jobs: next due")
        @config.poll_interval
      end

      private def wait(span : Time::Span) : Nil
        select
        when @wake.receive
        when timeout(span)
        end
      end

      private def run(job : Claimed) : Nil
        Job::Queue.perform(job, @queue, @database, @process_id, @tracer, -> { @stopping.get })
      rescue ex
        Log.error(exception: ex) { "recording job #{job.id} failed" }
        @tracer.report(ex, "jobs: recording")
      ensure
        @running_lock.synchronize { @running.delete(job.id) }
        wake
      end

      private def beat : Nil
        loop do
          select
          when @heartbeat_stop.receive
            break
          when timeout(@config.heartbeat_interval)
          end
          begin
            @queue.heartbeat(@process_id, @kind, @config.queues)
            released = @queue.release_orphans(@config.stale_after)
            unblocked = @queue.unblock_all
            Log.warn { "handed back #{released} job(s) of stopped processes" } if released > 0
            wake if released > 0 || unblocked > 0
          rescue ex
            Log.error(exception: ex) { "job heartbeat failed" }
            @tracer.report(ex, "jobs: heartbeat")
          end
        end
      end
    end
  end
end
