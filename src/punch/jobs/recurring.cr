module Punch
  # Runs a job on a schedule, in UTC:
  #
  # ```
  # @[Punch::Job::Recurring(cron: "0 3 * * *")] # every day at 03:00
  # @[Punch::Job::Recurring(every: 15.minutes)] # at :00, :15, :30, :45
  # ```
  #
  # The job is enqueued with an empty payload, so its fields need
  # defaults. Every process with workers runs the schedule; each run is
  # enqueued once all the same, by a unique key per job and time. Runs
  # missed while no process was up are not made up.
  annotation Job::Recurring
  end

  # Limits how many jobs of one key run at once, across processes:
  #
  # ```
  # @[Punch::Job::Concurrency(1, by: :invoice_id)] # one per invoice
  # @[Punch::Job::Concurrency(2, group: "stripe")] # two in all, shared by every job in the group
  # ```
  #
  # The key is the group (the job's type unless given), followed by the
  # value of the field *by* when given. A due job whose key is at its limit
  # waits as `blocked` until one finishes.
  annotation Job::Concurrency
  end

  class Job::Queue
    # One recurring job: its type, its schedule, and how to make its row
    # for a run.
    record Task, type : String, schedule : Schedule, entry : Proc(Time, Entry)

    # How long finished jobs (and, with the outbox, handed-over entries)
    # are kept; `PUNCH_JOB_RETENTION_HOURS`.
    class_property retention : Time::Span = 72.hours

    # The recurring jobs of this binary. Raises `ArgumentError` for a
    # cron expression that does not parse.
    def self.tasks : Array(Task)
      tasks = [] of Task
      {% for job in ::Punch::Job.includers %}
        {% for type in [job] + job.all_subclasses %}
          {% if !type.abstract? && (recurring = type.annotation(::Punch::Job::Recurring)) %}
            tasks << Job::Queue.task({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, {{ recurring[:cron] ? "cron".id : "every".id }}: {{ recurring[:cron] || recurring[:every] }})
          {% end %}
        {% end %}
      {% end %}
      tasks
    end

    # :nodoc:
    def self.task(type : J.class, *, cron : String? = nil, every : Time::Span? = nil) : Task forall J
      {% for ivar in J.instance_vars %}
        {% unless ivar.has_default_value? || ivar.type.nilable? %}
          {% raise "#{J} is recurring, so it runs with an empty payload; give #{J}##{ivar.name} a default or make it nilable (lib/punch/docs/jobs.md)." %}
        {% end %}
      {% end %}
      name = {{ J.name.stringify }}
      schedule = if cron
                   Cron.parse(cron)
                 elsif every
                   Every.new(every)
                 else
                   raise ArgumentError.new("takes cron: or every:")
                 end
      Task.new(name, schedule, ->(at : Time) { Job::Queue.entry(J.from_json("{}"), at, unique_key: "recurring:#{name}:#{at.to_unix_ms}") })
    rescue ex : ArgumentError
      raise ArgumentError.new("@[Punch::Job::Recurring] on #{J}: #{ex.message}")
    end

    # Enqueues recurring jobs when they come due. Runs next to the
    # workers, in every process that has them; unique keys make two
    # processes enqueue each run once.
    class Scheduler
      getter tasks : Array(Task)

      @stop = Channel(Nil).new(1)
      @started = false

      def initialize(@queue : Job::Queue, @tasks : Array(Task) = Job::Queue.tasks)
        @next = [] of Time?
      end

      # The next run of each task, in the order of `tasks`.
      def next_runs : Array(Time?)
        @next.empty? ? @tasks.map(&.schedule.next_after(Time.utc)) : @next.dup
      end

      def start(context : Fiber::ExecutionContext) : Nil
        return if @started || @tasks.empty?

        @started = true
        @next = @tasks.map(&.schedule.next_after(Time.utc))
        context.spawn(name: "punch-jobs-scheduler") { run }
      end

      def stop : Nil
        return unless @started

        @started = false
        @stop.send(nil)
      end

      # Enqueues every task due at *now* and moves it to its next run.
      # Returns the IDs written (none for a run another process enqueued).
      def tick(now : Time = Time.utc) : Array(Int64)
        @next = @tasks.map(&.schedule.next_after(now)) if @next.empty?
        due = [] of Entry
        @tasks.each_with_index do |task, index|
          at = @next[index] || next
          next if at > now
          due << task.entry.call(at)
          @next[index] = task.schedule.next_after(now)
        end
        @queue.insert(due)
      end

      private def run : Nil
        loop do
          begin
            tick
          rescue ex
            Log.error(exception: ex) { "enqueuing recurring jobs failed" }
          end
          soonest = @next.compact.min?
          wait = soonest ? (soonest - Time.utc).clamp(1.millisecond, 1.minute) : 1.minute
          select
          when @stop.receive
            break
          when timeout(wait)
          end
        end
      end
    end

    # Removes finished jobs, handed-over outbox entries, and the progress of
    # finished runs of jobs with steps past the retention window, every
    # hour.
    @[Punch::Job::Recurring(every: 1.hour)]
    struct Purge
      include Punch::Job

      def initialize
      end

      def perform(job : Punch::Job::Context) : Punch::Job::Result
        before = Time.utc - Job::Queue.retention
        removed = job.store.purge(before)
        handed_over = Job::Outbox.used? ? job.write { |db| Job::Outbox.purge(db, before) } : 0_i64
        progress = job.write { |db| Job::Steps::Progress.purge(db, before) }
        if (event = Trace.event).recording?
          event.set("punch.jobs.purged", removed)
          event.set("punch.outbox.purged", handed_over)
          event.set("punch.job_progress.purged", progress)
        end
        nil
      end
    end
  end

  module Auth
    # Removes expired sessions, API tokens, and one-time tokens, every
    # hour. Does nothing in an app without an actor.
    @[Punch::Job::Recurring(every: 1.hour)]
    struct Purge
      include Punch::Job

      def initialize
      end

      def perform(job : Punch::Job::Context) : Punch::Job::Result
        return unless Auth.used?

        removed = job.write { |db| Auth::Sessions.purge(db) + Auth::APITokens.purge(db) + Auth::OneTimeTokens.purge(db) }
        Trace.event.set("punch.auth.purged", removed) if Trace.event.recording?
        nil
      end
    end
  end
end
