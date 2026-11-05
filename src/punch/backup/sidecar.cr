module Punch::Backup
  # Litestream exited without being asked to.
  class SidecarExited < Exception
  end

  # Runs Litestream next to the app and restarts it when it exits (a
  # supervised sidecar).
  #
  # Exactly one Litestream may replicate a file, but several processes
  # open the same files: `serve` and `jobs`, and old and new process
  # during a deploy. So the sidecar runs Litestream only while it holds an
  # exclusive lock on `litestream.lock` in the storage directory, and the
  # others try again every few seconds. Litestream inherits the locked file,
  # so the lock stays taken as long as Litestream runs, also when the
  # process that started it was killed: no second Litestream starts beside
  # an orphaned one.
  #
  # `stop` asks Litestream to finish (SIGTERM: it syncs what is left) and
  # waits for it; `serve` and `jobs` call it after the databases close.
  class Sidecar
    Log = ::Log.for("punch.backup")

    getter litestream : Litestream
    @lock : File?
    @process : Process?
    @stopping = Atomic(Bool).new(false)
    @wake = Channel(Nil).new
    @done = Channel(Nil).new(1)
    @running = Atomic(Bool).new(false)
    @holder = Atomic(Bool).new(false)
    @restarts = Atomic(Int64).new(0)
    @started = false

    def initialize(@litestream : Litestream, @tracer : Trace::Tracer = Trace::Tracer.off,
                   @retry : Time::Span = 5.seconds, @backoff_max : Time::Span = 60.seconds,
                   @stop_timeout : Time::Span = 40.seconds, @output : Process::Redirect = :inherit)
    end

    # Whether this process holds the lock, so its Litestream replicates.
    def holder? : Bool
      @holder.get
    end

    # Whether this process's Litestream is running.
    def running? : Bool
      @running.get
    end

    # How often Litestream exited unasked and was started again.
    def restarts : Int64
      @restarts.get
    end

    def start : Nil
      return if @started

      @started = true
      spawn(name: "punch.backup.sidecar") { supervise }
    end

    # Stops Litestream, after waiting for its last sync, and releases the
    # lock. Safe to call more than once.
    def stop : Nil
      return unless @started
      return if @stopping.swap(true)

      @wake.close
      @process.try { |process| terminate(process, Signal::TERM) }
      select
      when @done.receive?
      when timeout(@stop_timeout)
        Log.warn { "Litestream did not stop within #{@stop_timeout.total_seconds.to_i} s: killing it" }
        @process.try { |process| terminate(process, Signal::KILL) }
        @done.receive?
      end
    end

    private def supervise : Nil
      backoff = 1.second
      until @stopping.get
        unless file = lock
          pause(@retry)
          next
        end
        started = Time.instant
        status = run(file)
        break if @stopping.get
        # Could not start; `run` reported it and paused.
        next unless status
        ran = Time.instant - started
        @restarts.add(1)
        backoff = ran >= @backoff_max ? 1.second : Math.min(backoff * 2, @backoff_max)
        message = "Litestream exited with #{describe(status)} after #{ran.total_seconds.round(1)} s; starting it again in #{backoff.total_seconds.to_i} s"
        Log.warn { message }
        @tracer.report(SidecarExited.new(message), "backup")
        pause(backoff)
      end
    rescue ex
      @tracer.report(ex, "backup")
    ensure
      unlock
      @done.send(nil)
    end

    # Litestream's exit status, or `nil` when it could not be started.
    private def run(lock : File) : Process::Status?
      @litestream.write_configuration
      program, args = @litestream.command
      # Inherited by Litestream only: see the class comment.
      lock.close_on_exec = false
      process = begin
        Process.new(program, args, env: Litestream.environment, clear_env: true, output: @output, error: @output)
      ensure
        lock.close_on_exec = true
      end
      @process = process
      @running.set(true)
      Log.info { "Litestream #{process.pid} replicating #{@litestream.names.join(", ")} to #{@litestream.config.display_url}" }
      # A stop that came before the process was known.
      terminate(process, Signal::TERM) if @stopping.get
      status = process.wait
      @running.set(false)
      status
    rescue ex : IO::Error | File::Error
      @running.set(false)
      @tracer.report(ex, "backup")
      pause(@backoff_max)
      nil
    end

    # The locked file, or `nil` while another process holds the lock.
    private def lock : File?
      file = @lock ||= File.open(@litestream.lock_path, "a")
      return file if @holder.get

      file.flock_exclusive(blocking: false)
      @holder.set(true)
      Log.info { "this process runs Litestream (#{@litestream.lock_path})" }
      file
    rescue IO::Error
      nil
    end

    private def unlock : Nil
      @holder.set(false)
      @lock.try(&.close)
      @lock = nil
    end

    private def pause(span : Time::Span) : Nil
      select
      when @wake.receive?
      when timeout(span)
      end
    end

    private def terminate(process : Process, signal : Signal) : Nil
      process.signal(signal) unless process.terminated?
    rescue RuntimeError
    end

    private def describe(status : Process::Status) : String
      if signal = status.exit_signal?
        "signal #{signal}"
      else
        "status #{status.exit_code? || status}"
      end
    end
  end
end
