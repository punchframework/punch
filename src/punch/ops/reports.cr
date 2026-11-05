module Punch::Ops
  # The time a performance report looks back.
  enum Window
    Hour
    Day
    Week

    def span : Time::Span
      case self
      in .hour? then 1.hour
      in .day?  then 24.hours
      in .week? then 7.days
      end
    end

    def label : String
      case self
      in .hour? then "last hour"
      in .day?  then "last 24 hours"
      in .week? then "last 7 days"
      end
    end
  end

  # What a performance report counts: requests by route, job runs by
  # type, or named queries.
  enum StatsKind
    Request
    Job
    Query

    def title : String
      case self
      in .request? then "Requests"
      in .job?     then "Jobs"
      in .query?   then "Named queries"
      end
    end
  end

  # What the `punch ops` commands print and the ops console's Queries
  # answer: one type per report, read from the store and the queue on the
  # box, or parsed from a remote console's JSON, and printed the same way. A
  # report's JSON is the same document locally and remotely, so an agent can
  # switch between them.
  module Reports
    # The time as reports print it, in UTC.
    def self.time(time : Time?) : String
      time ? time.to_utc.to_s("%Y-%m-%d %H:%M:%S") : "-"
    end

    # A duration in milliseconds as reports print it.
    def self.ms(value : Float64?) : String
      return "-" unless value

      value >= 100 ? "#{value.round.to_i64} ms" : "#{value.round(2)} ms"
    end

    # The first line of a stored message or error.
    def self.first_line(text : String?) : String
      text.try(&.lines.first?) || ""
    end

    # Requests in the last hour.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Requests
      include JSON::Serializable

      getter runs : Int64
      getter failed : Int64
      getter average_ms : Float64?

      def initialize(@runs, @failed, @average_ms)
      end
    end

    # `punch ops` and `GET /_punch`: open errors, jobs per state, worker
    # processes, requests in the last hour, and whether a restore waits
    # for confirmation. A part is `null` when its file is not open.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Overview
      include JSON::Serializable

      STATES = %w[ready scheduled running blocked failed incompatible]

      getter errors : Summary?
      getter jobs : Hash(String, Int64)?
      getter processes : Int32?
      getter requests : Requests?
      getter? recovering : Bool

      def initialize(@errors, @jobs, @processes, @requests, @recovering)
      end

      def self.build(store : Store?, queue : Job::Queue?, recovering : Bool) : self
        jobs = queue.try do |open|
          totals = open.counts.group_by(&.state).transform_values(&.sum(&.jobs))
          STATES.to_h { |state| {state, totals[state]? || 0_i64} }
        end
        requests = store.try do |ops|
          stats = ops.stats("request", since: Time.utc - 1.hour)
          runs = stats.sum(&.count)
          Requests.new(runs, stats.sum(&.failed), runs > 0 ? stats.sum(&.total_ms) / runs : nil)
        end
        new(store.try(&.summary), jobs, queue.try(&.processes.size), requests, recovering)
      end

      def to_text(io : IO) : Nil
        io.puts "recovery mode: a restore waits for punch recovery:confirm" if recovering?
        if errors = @errors
          io.puts "errors      #{errors.open_errors} open, #{errors.occurrences_24h} occurrences in 24 h"
          io.puts "job runs    #{errors.failed_runs_24h} of #{errors.runs_24h} failed in 24 h"
        else
          io.puts "errors      ops.db is not open"
        end
        if jobs = @jobs
          io.puts "jobs        #{jobs.join(", ") { |state, count| "#{count} #{state}" }}"
          io.puts "processes   #{@processes || 0}"
        else
          io.puts "jobs        queue.db is not open"
        end
        @requests.try do |requests|
          io.puts "requests    #{requests.runs} in the last hour, #{requests.failed} failed, average #{Reports.ms(requests.average_ms)}"
        end
      end
    end

    # One error group in a list: everything but the backtrace.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct ErrorEntry
      include JSON::Serializable

      getter id : Int64
      getter fingerprint : String
      getter exception : String
      getter source : String
      getter message : String?
      getter occurrences : Int64
      getter first_seen : Time
      getter last_seen : Time
      getter resolved_at : Time?

      def initialize(@id, @fingerprint, @exception, @source, @message, @occurrences, @first_seen, @last_seen, @resolved_at)
      end

      def self.new(group : ErrorGroup) : self
        new(group.id, group.fingerprint, group.exception, group.source, group.message, group.occurrences,
          group.first_seen, group.last_seen, group.resolved_at)
      end

      def resolved? : Bool
        !resolved_at.nil?
      end
    end

    # `punch ops:errors` and `GET /_punch/errors`: error groups, most
    # recently seen first.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Errors
      include JSON::Serializable

      getter errors : Array(ErrorEntry)

      def initialize(@errors)
      end

      def self.build(store : Store, resolved : Bool?, limit : Int32) : self
        new(store.errors(resolved: resolved, limit: limit).map { |group| ErrorEntry.new(group) })
      end

      def to_text(io : IO) : Nil
        return io.puts "No errors." if @errors.empty?

        @errors.each do |group|
          io << group.id.to_s.rjust(6) << "  " << (group.resolved? ? "resolved" : "open").ljust(8) << "  "
          io << group.occurrences.to_s.rjust(6) << "x  " << Reports.time(group.last_seen) << "  " << group.exception << " in " << group.source << '\n'
          group.message.try { |message| io << "        " << message.lines.first? << '\n' }
        end
      end
    end

    # `punch ops:error ID` and `GET /_punch/errors/:error_id`: one group
    # with its backtrace and its latest occurrences, each with the ID of
    # its stored wide event (`ops:record`).
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct ErrorDetail
      include JSON::Serializable

      getter id : Int64
      getter fingerprint : String
      getter exception : String
      getter source : String
      getter message : String?
      getter backtrace : String?
      getter occurrences : Int64
      getter first_seen : Time
      getter last_seen : Time
      getter resolved_at : Time?
      getter latest : Array(Occurrence)

      def initialize(@id, @fingerprint, @exception, @source, @message, @backtrace, @occurrences, @first_seen, @last_seen,
                     @resolved_at, @latest)
      end

      # The group *id* with its latest occurrences, or `nil`.
      def self.build(store : Store, id : Int64) : self?
        group = store.error(id) || return
        new(group.id, group.fingerprint, group.exception, group.source, group.message, group.backtrace, group.occurrences,
          group.first_seen, group.last_seen, group.resolved_at, store.occurrences(id))
      end

      def to_text(io : IO) : Nil
        io.puts "error #{@id}  #{@exception} in #{@source}"
        io.puts "state         #{@resolved_at ? "resolved #{Reports.time(@resolved_at)}" : "open"}"
        io.puts "occurrences   #{@occurrences}, first #{Reports.time(@first_seen)}, last #{Reports.time(@last_seen)}"
        @message.try { |message| io.puts "message       #{message.gsub("\n", "\n              ")}" }
        @backtrace.try { |trace| io.puts "backtrace     #{trace.gsub("\n", "\n              ")}" }
        io.puts "latest" unless @latest.empty?
        @latest.each do |occurrence|
          io << "  " << Reports.time(occurrence.at) << "  trace " << (occurrence.trace_id || "-")
          occurrence.record_id.try { |record| io << "  record " << record }
          io << '\n'
        end
      end
    end

    # What an action on an error or a job answers: its ID and the state
    # it is in now.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Changed
      include JSON::Serializable

      getter id : Int64
      getter state : String

      def initialize(@id, @state)
      end

      def to_text(io : IO) : Nil
        io.puts "#{@id} is #{@state}."
      end
    end

    # What retrying every failed job of a type answers.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Retried
      include JSON::Serializable

      getter job_type : String
      getter retried : Int64

      def initialize(@job_type, @retried)
      end

      def to_text(io : IO) : Nil
        io.puts "#{@retried} failed #{@job_type} #{@retried == 1 ? "job is" : "jobs are"} ready again."
      end
    end

    # `punch ops:jobs` and `GET /_punch/jobs`: jobs per queue and state,
    # paused queues, failed jobs grouped by type, parked (incompatible)
    # and running jobs, and the processes running workers.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Jobs
      include JSON::Serializable

      getter counts : Array(Job::Queue::Count)
      getter paused : Array(String)
      getter failed : Array(Job::Queue::FailedGroup)
      getter parked : Array(Job::Queue::Row)
      getter running : Array(Job::Queue::Row)
      getter processes : Array(Job::Queue::Process)

      def initialize(@counts, @paused, @failed, @parked, @running, @processes)
      end

      def self.build(queue : Job::Queue) : self
        new(queue.counts, queue.paused, queue.failed_groups, queue.list(state: "incompatible"), queue.list(state: "running"),
          queue.processes)
      end

      def to_text(io : IO) : Nil
        names = (@counts.map(&.queue) + @paused).uniq!.sort!
        io.puts "No jobs yet." if names.empty?
        names.each do |name|
          states = @counts.select(&.queue.==(name)).join(", ") { |count| "#{count.jobs} #{count.state}" }
          io << name.ljust(16) << (@paused.includes?(name) ? "paused  " : "") << states << '\n'
        end
        unless @failed.empty?
          io.puts "failed"
          @failed.each do |group|
            io << "  " << group.count.to_s.rjust(5) << "x  " << group.type << "  latest " << group.latest_id
            io << "  " << Reports.first_line(group.error) << '\n'
          end
        end
        rows(io, "parked (incompatible payloads)", @parked)
        rows(io, "running", @running)
        io.puts "processes   #{@processes.size}#{@processes.empty? ? "" : ": "}#{@processes.join(", ") { |process| "#{process.kind} #{process.id}" }}"
      end

      private def rows(io : IO, title : String, rows : Array(Job::Queue::Row)) : Nil
        return if rows.empty?

        io.puts title
        rows.each do |row|
          io << "  " << row.id.to_s.rjust(6) << "  " << row.type << "  " << row.queue << "  " << row.attempts << '/' << row.max_attempts
          io << "  " << Reports.first_line(row.error) << '\n'
        end
      end
    end

    # One run of a job, from its stored wide event.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Run
      include JSON::Serializable

      getter record_id : Int64
      getter at : Time
      getter duration_ms : Float64?
      getter outcome : String?
      getter trace_id : String?

      def initialize(@record_id, @at, @duration_ms, @outcome, @trace_id)
      end
    end

    # `punch ops:job ID` and `GET /_punch/jobs/:job_id`: one job with its
    # payload, last error, and its runs in `ops.db` (`null` when that is
    # not open).
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct JobDetail
      include JSON::Serializable

      getter job : Job::Queue::Row
      getter state : String
      getter runs : Array(Run)?

      def initialize(@job, @state, @runs)
      end

      # The job *id* with its runs, or `nil`.
      def self.build(queue : Job::Queue, store : Store?, id : Int64) : self?
        row = queue.find(id) || return
        runs = store.try &.records(job_id: id).map do |record|
          outcome = JSON.parse(record.fields)["punch.job.outcome"]?.try(&.as_s?) || (record.failed ? "failed" : nil)
          Run.new(record.id, record.at, record.duration_ms, outcome, record.trace_id)
        end
        new(row, row.display_state(Time.utc), runs)
      end

      def to_text(io : IO) : Nil
        row = @job
        io.puts "job #{row.id}  #{row.type}"
        io.puts "state         #{@state}"
        io.puts "queue         #{row.queue}, priority #{row.priority}"
        io.puts "attempts      #{row.attempts} of #{row.max_attempts}"
        io.puts "enqueued      #{Reports.time(row.enqueued_at)}"
        io.puts "run at        #{Reports.time(row.run_at)}"
        row.finished_at.try { |finished| io.puts "finished      #{Reports.time(finished)}" }
        io.puts "payload       #{row.payload}"
        row.error.try { |error| io.puts "error         #{error.gsub("\n", "\n              ")}" }
        runs = @runs
        if runs.nil?
          io.puts "runs          ops.db is not open"
        elsif runs.empty?
          io.puts "runs          none recorded (sampled, or past retention)"
        else
          io.puts "runs"
          runs.each do |run|
            io << "  " << Reports.time(run.at) << "  " << Reports.ms(run.duration_ms).rjust(10) << "  " << (run.outcome || "-")
            io << "  record " << run.record_id << '\n'
          end
        end
      end
    end

    # One route, job type, or named query over a window.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct StatsEntry
      include JSON::Serializable

      getter name : String
      getter runs : Int64
      getter failed : Int64
      getter p50_ms : Float64?
      getter p95_ms : Float64?
      getter p99_ms : Float64?
      getter max_ms : Float64
      getter average_ms : Float64
      getter total_ms : Float64
      # Per run, for requests and jobs.
      getter writer_wait_ms : Float64
      getter queries_per_run : Float64
      # Rows read or changed, for named queries.
      getter rows : Int64
      # Answers replayed for an idempotency key, for requests.
      getter replays : Int64

      def initialize(@name, @runs, @failed, @p50_ms, @p95_ms, @p99_ms, @max_ms, @average_ms, @total_ms, @writer_wait_ms,
                     @queries_per_run, @rows, @replays)
      end

      def self.new(stats : Stats) : self
        runs = Math.max(stats.count, 1)
        new(stats.name, stats.count, stats.failed, stats.percentile(0.5), stats.percentile(0.95), stats.percentile(0.99),
          stats.max_ms, stats.average_ms, stats.total_ms, stats.wait_ms / runs, (stats.queries / runs).round(1), stats.rows,
          stats.replays)
      end
    end

    # A slow or failed request whose wide event is kept.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Slow
      include JSON::Serializable

      getter record_id : Int64
      getter at : Time
      getter name : String
      getter duration_ms : Float64?
      getter status : Int64?
      getter trace_id : String?

      def initialize(@record_id, @at, @name, @duration_ms, @status, @trace_id)
      end

      def self.new(record : StoredRecord) : self
        status = JSON.parse(record.fields)["http.response.status_code"]?.try(&.as_i64?)
        new(record.id, record.at, record.name, record.duration_ms, status, record.trace_id)
      end
    end

    # `punch ops:performance` and `GET /_punch/performance`: per route,
    # job type, or named query over a window, the most time spent first;
    # for requests also the slowest ones kept (`ops:slow`).
    # Percentiles are the upper bound of the duration bucket they fall in.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct Performance
      include JSON::Serializable

      getter kind : StatsKind
      getter window : Window
      getter since : Time
      getter stats : Array(StatsEntry)
      getter slowest : Array(Slow)?

      def initialize(@kind, @window, @since, @stats, @slowest)
      end

      def self.build(store : Store, kind : StatsKind, window : Window, limit : Int32 = 200) : self
        since = Time.utc - window.span
        slowest = kind.request? ? store.slowest(since: since, limit: 20).map { |record| Slow.new(record) } : nil
        new(kind, window, since, store.stats(kind.to_s.downcase, since: since, limit: limit).map { |stats| StatsEntry.new(stats) }, slowest)
      end

      def to_text(io : IO) : Nil
        io.puts "#{@kind.title}, #{@window.label}, the most time spent first"
        return io.puts "Nothing recorded." if @stats.empty?

        io.puts "#{"runs".rjust(8)} #{"failed".rjust(6)} #{"p50".rjust(10)} #{"p95".rjust(10)} #{"p99".rjust(10)} #{"max".rjust(10)} #{"total".rjust(10)}  name"
        @stats.each do |row|
          io << row.runs.to_s.rjust(8) << ' ' << row.failed.to_s.rjust(6) << ' ' << Reports.ms(row.p50_ms).rjust(10) << ' '
          io << Reports.ms(row.p95_ms).rjust(10) << ' ' << Reports.ms(row.p99_ms).rjust(10) << ' ' << Reports.ms(row.max_ms).rjust(10) << ' '
          io << "#{(row.total_ms / 1000).round(2)} s".rjust(10) << "  " << row.name << '\n'
        end
      end
    end

    # `punch ops:slow`: the slowest requests kept over a window, from
    # the performance report.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct SlowRequests
      include JSON::Serializable

      getter window : Window
      getter since : Time
      getter slowest : Array(Slow)

      def initialize(@window, @since, @slowest)
      end

      def self.new(performance : Performance) : self
        new(performance.window, performance.since, performance.slowest || [] of Slow)
      end

      def to_text(io : IO) : Nil
        if @slowest.empty?
          return io.puts "No slow or failed request kept #{@window.label} (kept from PUNCH_OPS_SLOW_MS)."
        end

        @slowest.each do |slow|
          io << Reports.time(slow.at) << "  " << Reports.ms(slow.duration_ms).rjust(10) << "  " << (slow.status.try(&.to_s) || "-").rjust(3)
          io << "  " << slow.name << "  record " << slow.record_id << '\n'
        end
      end
    end

    # `punch ops:record ID` and `GET /_punch/records/:record_id`: one
    # stored wide event (a failed or slow request, a job run), every
    # field.
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct WideEvent
      include JSON::Serializable

      getter id : Int64
      getter at : Time
      getter kind : String
      getter name : String
      getter trace_id : String?
      getter duration_ms : Float64?
      getter? failed : Bool
      getter job_id : Int64?
      getter fields : Hash(String, JSON::Any)

      def initialize(@id, @at, @kind, @name, @trace_id, @duration_ms, @failed, @job_id, @fields)
      end

      def self.new(record : StoredRecord) : self
        new(record.id, record.at, record.kind, record.name, record.trace_id, record.duration_ms, record.failed, record.job_id,
          Hash(String, JSON::Any).from_json(record.fields))
      end

      def to_text(io : IO) : Nil
        io.puts "record #{@id}  #{@name}"
        io.puts "at            #{Reports.time(@at)}"
        io.puts "duration      #{Reports.ms(@duration_ms)}#{failed? ? ", failed" : ""}"
        @trace_id.try { |id| io.puts "trace         #{id}" }
        @job_id.try { |id| io.puts "job           #{id}" }
        width = @fields.keys.max_of?(&.size) || 0
        @fields.each do |key, value|
          io << "  " << key.ljust(width) << "  " << (value.as_s? || value.to_json) << '\n'
        end
      end
    end
  end
end
