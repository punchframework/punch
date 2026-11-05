module Punch::CLI::Commands
  # Helpers shared by the job commands, which work on `queue.db` in
  # `PUNCH_STORAGE` (docs/jobs.md), also while the app runs.
  module JobsCommand
    # Runs *block* with the queue, or answers without one.
    def self.with_queue(& : Punch::Job::Queue, String -> Report | Failure) : Report | Failure
      settings = Config.settings
      return settings if settings.is_a?(Failure)

      path = File.join(settings.storage, "queue.db")
      return Failure.new("no_database", "#{path} does not exist; serve creates it.") unless File.exists?(path)

      database = Punch::Database.open(path, name: "queue", config: Punch::Database::Config.new(readers: 1))
      begin
        yield Punch::Job::Queue.new(database), path
      ensure
        database.close
      end
    rescue ex : Punch::Database::Error | Punch::Database::FilesystemError | Punch::Job::Queue::Error
      Failure.new("database_error", ex.message || "database error")
    end

    # The value of `--name VALUE` in *args*, removing both.
    def self.option(args : Array(String), name : String) : String? | Failure
      index = args.index(name) || return
      value = args[index + 1]?
      return Failure.usage("missing_value", "#{name} needs a value") if value.nil? || value.starts_with?("--")

      args.delete_at(index, 2)
      value
    end

    # The job ID in *args*, the only argument left.
    def self.id(args : Array(String), usage : String) : Int64 | Failure
      return Failure.usage("missing_argument", "Usage: #{usage}") if args.empty?
      return Failure.usage("unexpected_argument", "Usage: #{usage}") unless args.size == 1

      args[0].to_i64?.try { |id| id > 0 ? id : nil } || Failure.usage("invalid_id", "Not a job ID: #{args[0].inspect}")
    end

    def self.time(time : Time?) : String
      time ? time.to_s("%Y-%m-%d %H:%M:%S") : "-"
    end
  end

  # Lists jobs, newest first.
  class JobsList < Command
    command "jobs:list", "List jobs in queue.db: punch jobs:list [--state S] [--queue Q] [--type T] [--limit N]"

    struct Result
      include Report

      def initialize(@rows : Array(Punch::Job::Queue::Row), @now : Time)
      end

      def to_text(io : IO) : Nil
        return io.puts "No jobs." if @rows.empty?

        @rows.each do |row|
          io << row.id.to_s.rjust(8) << "  " << row.display_state(@now).ljust(10) << "  " << row.queue.ljust(12) << "  "
          io << "#{row.attempts}/#{row.max_attempts}".ljust(6) << "  " << JobsCommand.time(row.run_at) << "  " << row.type << '\n'
          row.error.try { |error| io << "          " << error.lines.first? << '\n' } if row.state.in?("failed", "discarded", "ready")
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "jobs" do
            json.array do
              @rows.each do |row|
                json.object do
                  json.field "id", row.id
                  json.field "queue", row.queue
                  json.field "type", row.type
                  json.field "version", row.version
                  json.field "state", row.display_state(@now)
                  json.field "priority", row.priority
                  json.field "run_at", row.run_at
                  json.field "attempts", row.attempts
                  json.field "max_attempts", row.max_attempts
                  json.field "unique_key", row.unique_key
                  json.field "concurrency_key", row.concurrency_key
                  json.field "claimed_by", row.claimed_by
                  json.field "enqueued_at", row.enqueued_at
                  json.field "finished_at", row.finished_at
                  json.field "error", row.error
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      state = JobsCommand.option(args, "--state")
      queue = JobsCommand.option(args, "--queue")
      type = JobsCommand.option(args, "--type")
      limit = JobsCommand.option(args, "--limit")
      {state, queue, type, limit}.each { |value| return value if value.is_a?(Failure) }
      return Failure.usage("unexpected_argument", "Usage: punch jobs:list [--state S] [--queue Q] [--type T] [--limit N]") unless args.empty?
      if state && !(Punch::Job::Queue::STATES + ["scheduled"]).includes?(state)
        return Failure.usage("invalid_state", "--state is one of #{(Punch::Job::Queue::STATES + ["scheduled"]).join(", ")}")
      end

      count = limit ? limit.as(String).to_i? : 50
      return Failure.usage("invalid_limit", "--limit is a number from 1 to 10000") unless count && 1 <= count <= 10_000

      JobsCommand.with_queue do |jobs|
        Result.new(jobs.list(state: state.as(String?), queue: queue.as(String?), type: type.as(String?), limit: count), Time.utc)
      end
    end
  end

  # One job with its payload and last error.
  class JobsShow < Command
    command "jobs:show", "Show one job with its payload and last error: punch jobs:show ID"

    struct Result
      include Report

      def initialize(@row : Punch::Job::Queue::Row, @now : Time, @progress : Punch::Job::Steps::Saved? = nil,
                     @steps : Array(String)? = nil)
      end

      def to_text(io : IO) : Nil
        io.puts "job #{@row.id}  #{@row.type} (version #{@row.version})"
        io.puts "state         #{@row.display_state(@now)}"
        io.puts "queue         #{@row.queue}, priority #{@row.priority}"
        io.puts "attempts      #{@row.attempts} of #{@row.max_attempts}"
        io.puts "enqueued      #{JobsCommand.time(@row.enqueued_at)}"
        io.puts "run at        #{JobsCommand.time(@row.run_at)}"
        io.puts "finished      #{JobsCommand.time(@row.finished_at)}"
        @row.unique_key.try { |key| io.puts "unique key    #{key}" }
        @row.concurrency_key.try { |key| io.puts "concurrency   #{key}" }
        @row.claimed_by.try { |process| io.puts "claimed by    #{process}" }
        io.puts "payload       #{@row.payload}"
        steps_text(io)
        @row.error.try { |error| io.puts "error         #{error.gsub("\n", "\n              ")}" }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "id", @row.id
          json.field "queue", @row.queue
          json.field "type", @row.type
          json.field "version", @row.version
          json.field "state", @row.display_state(@now)
          json.field "priority", @row.priority
          json.field "run_at", @row.run_at
          json.field "attempts", @row.attempts
          json.field "max_attempts", @row.max_attempts
          json.field "unique_key", @row.unique_key
          json.field "concurrency_key", @row.concurrency_key
          json.field "claimed_by", @row.claimed_by
          json.field "enqueued_at", @row.enqueued_at
          json.field "finished_at", @row.finished_at
          json.field "error", @row.error
          json.field "payload", JSON.parse(@row.payload)
          if steps = @steps
            json.field "steps", steps
            json.field "progress" do
              if progress = @progress
                json.object do
                  json.field "step", progress.step
                  json.field "cursor", progress.cursor.try { |cursor| JSON.parse(cursor) }
                  json.field "saves", progress.saves
                  json.field "updated_at", progress.updated_at
                  json.field "finished_at", progress.finished_at
                end
              else
                json.null
              end
            end
          end
        end
      end

      # Where a job with steps stopped: its step of all, and the cursor.
      private def steps_text(io : IO) : Nil
        steps = @steps || return
        progress = @progress
        position = if progress.nil?
                     "not started (#{steps.join(", ")})"
                   elsif progress.finished?
                     "all #{steps.size} done (#{steps.join(", ")})"
                   else
                     step = progress.step || ""
                     "#{step} (#{(steps.index(step) || -1) + 1} of #{steps.size}: #{steps.join(", ")})"
                   end
        io.puts "step          #{position}"
        return unless progress

        progress.cursor.try { |cursor| io.puts "cursor        #{cursor}" } unless progress.finished?
        io.puts "saved         #{JobsCommand.time(progress.updated_at)}, #{progress.saves} save#{progress.saves == 1 ? "" : "s"}"
      end
    end

    def run(args : Array(String)) : Report | Failure
      id = JobsCommand.id(args, "punch jobs:show ID")
      return id if id.is_a?(Failure)

      JobsCommand.with_queue do |jobs, path|
        row = jobs.find(id)
        next Failure.new("not_found", "No job #{id}.") unless row

        steps = Punch::Job::Steps.names[row.type]?
        progress = steps ? JobsShow.progress(File.join(File.dirname(path), "primary.db"), row.unique_key || "job-#{row.id}") : nil
        Result.new(row, Time.utc, progress, steps)
      end
    end
  end

  class JobsShow
    # The saved progress of a job with steps, from `primary.db`.
    def self.progress(path : String, key : String) : Punch::Job::Steps::Saved?
      return unless File.exists?(path)

      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1))
      begin
        return unless Punch::Job::Steps::Progress.present?(database)

        database.read { |db| Punch::Job::Steps::Progress.load(db, key) }
      ensure
        database.close
      end
    end
  end

  # Jobs per queue and state, paused queues, and the processes running
  # workers.
  class JobsStats < Command
    command "jobs:stats", "Show jobs per queue and state, paused queues, and worker processes"

    struct Result
      include Report

      def initialize(@counts : Array(Punch::Job::Queue::Count), @paused : Array(String), @processes : Array(Punch::Job::Queue::Process))
      end

      def to_text(io : IO) : Nil
        io.puts "No jobs." if @counts.empty?
        @counts.group_by(&.queue).each do |queue, counts|
          io << queue << (@paused.includes?(queue) ? " (paused)" : "") << '\n'
          counts.each { |count| io << "  " << count.state.ljust(10) << count.jobs.to_s.rjust(10) << '\n' }
        end
        (@paused - @counts.map(&.queue)).each { |queue| io.puts "#{queue} (paused, empty)" }
        io.puts @processes.empty? ? "No worker processes." : "Worker processes:"
        @processes.each do |process|
          io.puts "  #{process.id}  #{process.kind}  queues #{process.queues}  heartbeat #{JobsCommand.time(process.heartbeat_at)}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "counts", @counts
          json.field "paused", @paused
          json.field "processes", @processes
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      JobsCommand.with_queue { |jobs| Result.new(jobs.counts, jobs.paused, jobs.processes) }
    end
  end

  # What a command that changes one job reports.
  struct JobChanged
    include Report

    def initialize(@id : Int64, @state : String)
    end

    def to_text(io : IO) : Nil
      io.puts "Job #{@id} is #{@state}."
    end

    def to_json(json : JSON::Builder) : Nil
      json.object { json.field "id", @id; json.field "state", @state }
    end
  end

  # Makes a failed or discarded job ready again, with fresh attempts.
  class JobsRetry < Command
    command "jobs:retry", "Run a failed or discarded job again: punch jobs:retry ID"

    def run(args : Array(String)) : Report | Failure
      id = JobsCommand.id(args, "punch jobs:retry ID")
      return id if id.is_a?(Failure)

      JobsCommand.with_queue do |jobs|
        jobs.retry_job(id) ? JobChanged.new(id, "ready") : Failure.new("not_retryable", "No failed or discarded job #{id}.")
      end
    end
  end

  # Discards a waiting or failed job.
  class JobsDiscard < Command
    command "jobs:discard", "Discard a waiting or failed job: punch jobs:discard ID"

    def run(args : Array(String)) : Report | Failure
      id = JobsCommand.id(args, "punch jobs:discard ID")
      return id if id.is_a?(Failure)

      JobsCommand.with_queue do |jobs|
        jobs.discard_job(id) ? JobChanged.new(id, "discarded") : Failure.new("not_discardable", "No waiting or failed job #{id}; a running job cannot be discarded.")
      end
    end
  end
end

module Punch::CLI::Commands
  # What `jobs:pause` and `jobs:resume` report.
  struct QueuePaused
    include Report

    def initialize(@queue : String, @paused : Bool, @changed : Bool)
    end

    def to_text(io : IO) : Nil
      io.puts "Queue #{@queue} #{@changed ? "is now" : "was already"} #{@paused ? "paused" : "running"}."
    end

    def to_json(json : JSON::Builder) : Nil
      json.object { json.field "queue", @queue; json.field "paused", @paused; json.field "changed", @changed }
    end
  end

  # Stops every process from claiming jobs of a queue; running jobs finish.
  class JobsPause < Command
    command "jobs:pause", "Stop claiming jobs from a queue in every process: punch jobs:pause QUEUE"

    def run(args : Array(String)) : Report | Failure
      JobsCommand.queue_name(args, "punch jobs:pause QUEUE") do |name|
        JobsCommand.with_queue { |jobs| QueuePaused.new(name, true, jobs.pause(name)) }
      end
    end
  end

  class JobsResume < Command
    command "jobs:resume", "Claim jobs from a paused queue again: punch jobs:resume QUEUE"

    def run(args : Array(String)) : Report | Failure
      JobsCommand.queue_name(args, "punch jobs:resume QUEUE") do |name|
        JobsCommand.with_queue { |jobs| QueuePaused.new(name, false, jobs.resume(name)) }
      end
    end
  end

  module JobsCommand
    # The queue name that is the only argument, given to the block.
    def self.queue_name(args : Array(String), usage : String, & : String -> Report | Failure) : Report | Failure
      return Failure.usage("missing_argument", "Usage: #{usage}") if args.empty?
      return Failure.usage("unexpected_argument", "Usage: #{usage}") unless args.size == 1
      return Failure.usage("invalid_queue", "Not a queue name (lowercase letters, digits, and _): #{args[0].inspect}") unless args[0].matches?(/\A[a-z][a-z0-9_]{0,62}\z/)

      yield args[0]
    end
  end

  # The job types of the application it is compiled into, with their
  # options, concurrency limits, and schedules with the next run. Fails
  # when a schedule does not parse, which `punch check` reports.
  class JobsTypes < Command
    command "jobs:types", "List the job types with queue, attempts, priority, concurrency, and schedule"

    struct Result
      include Report

      def initialize(@types : Array(Punch::Job::Queue::Registry::Description), @schedules : Hash(String, {String, Time?}),
                     @reads : Hash(String, Array(Int32)))
      end

      def to_text(io : IO) : Nil
        @types.each do |type|
          io.puts type.type
          reads = @reads[type.type]? || [1]
          io.puts "  queue #{type.queue}, #{type.attempts} attempts, priority #{type.priority}, payload version #{reads.first}#{reads.size > 1 ? " (reads #{reads.join(", ")})" : ""}"
          type.concurrency.try { |key| io.puts "  at most #{type.concurrency_limit} at once per #{key}" }
          if schedule = @schedules[type.type]?
            io.puts "  #{schedule[0]}, next #{JobsCommand.time(schedule[1])} UTC"
          end
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "types" do
            json.array do
              @types.each do |type|
                json.object do
                  json.field "type", type.type
                  json.field "queue", type.queue
                  json.field "attempts", type.attempts
                  json.field "priority", type.priority
                  json.field "version", @reads[type.type]?.try(&.first)
                  json.field "reads", @reads[type.type]? || [] of Int32
                  json.field "concurrency", type.concurrency
                  json.field "concurrency_limit", type.concurrency_limit
                  schedule = @schedules[type.type]?
                  json.field "schedule", schedule.try(&.[0])
                  json.field "next_run", schedule.try(&.[1])
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      now = Time.utc
      schedules = Punch::Job::Queue.tasks.to_h { |task| {task.type, {task.schedule.to_s, task.schedule.next_after(now)}} }
      Result.new(Punch::Job::Queue::Registry.descriptions, schedules, Punch::Job::Queue::Registry.reads)
    rescue ex : ArgumentError
      Failure.new("invalid_schedule", ex.message || "invalid schedule")
    end
  end
end

module Punch::CLI::Commands
  # Unfinished jobs per payload version, next to the versions this binary
  # reads: a frozen type can be deleted once no job and no outbox entry of
  # its version is left, in every environment.
  class JobsVersions < Command
    command "jobs:versions", "Count unfinished jobs and outbox entries per payload version, against the versions this binary reads"

    record Version, version : Int32, readable : Bool, states : Hash(String, Int64), outbox : Int64 do
      def jobs : Int64
        states.values.sum
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "version", version
          json.field "readable", readable
          json.field "jobs", jobs
          json.field "states", states
          json.field "outbox", outbox
        end
      end
    end

    record Type, type : String, reads : Array(Int32), versions : Array(Version) do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "type", type
          json.field "known", !reads.empty?
          json.field "version", reads.first?
          json.field "reads", reads
          json.field "versions", versions
        end
      end
    end

    struct Result
      include Report

      def initialize(@types : Array(Type))
      end

      def to_text(io : IO) : Nil
        @types.each do |type|
          if current = type.reads.first?
            io.puts "#{type.type}  version #{current}#{type.reads.size > 1 ? ", reads #{type.reads.join(", ")}" : ""}"
          else
            io.puts "#{type.type}  not a job type of this binary"
          end
          type.versions.each do |version|
            io << "  version " << version.version << ": "
            if version.jobs == 0 && version.outbox == 0
              io << "none left" << (version.version == type.reads.first? ? "" : "; its frozen type can go once every environment says so") << '\n'
              next
            end
            io << version.jobs << (version.jobs == 1 ? " job" : " jobs")
            io << " (" << version.states.join(", ") { |state, count| "#{state} #{count}" } << ")" unless version.states.empty?
            io << ", " << version.outbox << " in the outbox" if version.outbox > 0
            if !version.readable && (current = type.reads.first?)
              io << (version.version > current ? "; newer than this binary reads" : "; nothing here reads it: parked when claimed")
            end
            io << '\n'
          end
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "types", @types }
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      JobsCommand.with_queue do |jobs, path|
        outbox = JobsVersions.outbox(File.join(File.dirname(path), "primary.db"))
        Result.new(JobsVersions.types(Punch::Job::Queue::Registry.reads, jobs.version_counts, outbox))
      end
    end

    # Pending outbox entries per type and version, when `primary.db` has
    # an outbox.
    def self.outbox(path : String) : Array({String, Int32, Int64})
      return [] of {String, Int32, Int64} unless File.exists?(path)

      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1))
      begin
        return [] of {String, Int32, Int64} unless Punch::Job::Outbox.present?(database)

        database.read { |db| Punch::Job::Outbox.pending_versions(db) }
      ensure
        database.close
      end
    end

    # Every type this binary reads and every type with unfinished jobs, with
    # each version it reads or that has jobs.
    def self.types(reads : Hash(String, Array(Int32)), counts : Array(Punch::Job::Queue::VersionCount),
                   outbox : Array({String, Int32, Int64})) : Array(Type)
      names = (reads.keys + counts.map(&.type) + outbox.map(&.[0])).uniq!.sort!
      names.map do |name|
        known = reads[name]? || [] of Int32
        numbers = (known + counts.select(&.type.== name).map(&.version) + outbox.select(&.[0].== name).map(&.[1])).uniq!.sort!
        versions = numbers.map do |number|
          states = counts.select { |count| count.type == name && count.version == number }.to_h { |count| {count.state, count.jobs} }
          pending = outbox.find { |entry| entry[0] == name && entry[1] == number }.try(&.[2]) || 0_i64
          Version.new(number, known.includes?(number), states, pending)
        end
        Type.new(name, known, versions)
      end
    end
  end
end
