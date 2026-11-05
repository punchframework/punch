module Punch::Ops
  # The event sink that fills `ops.db`. It receives every wide event,
  # decides what to keep, and writes in batches from a fiber of its own, so
  # requests never wait for `ops.db`:
  #
  # - Every exception recorded in a trace (`Span#record_exception`) counts
  #   towards its error group, and the trace's wide event is kept with it.
  # - Failed wide events are kept: 5xx responses, failed job runs, reports.
  # - Successful job runs and the events a trace committed are kept for a
  #   share of traces, *sample* (`PUNCH_OPS_SAMPLE_PERCENT`), decided by
  #   trace ID like the tracer's sampling, so a request and the jobs it
  #   enqueued are kept or left out together.
  # - Successful requests are kept only when they took `Ops.slow` or
  #   longer, at most `SLOW_PER_BUCKET` per route and stats bucket.
  # - Every request, job run, and named query counts towards the stats of
  #   its name (`punch_ops_stats`), added up in memory and written every
  #   *flush* and at `close`.
  #
  # When *capacity* events are waiting, further ones are dropped and
  # counted rather than slowing requests down; the count is logged.
  class Sink < Trace::EventSink
    Log = ::Log.for("punch.ops")

    # Slow requests kept per route and stats bucket, at most: an incident
    # that slows everything keeps a sample, not every request.
    SLOW_PER_BUCKET = 10

    getter sample : Float64
    @events : Channel(Trace::Span)
    @done = Channel(Nil).new
    @dropped = Atomic(Int64).new(0)
    @reported = 0_i64
    @tallies = Tallies.new
    @slow_kept = {} of {String, Int64} => Int32
    @flushed = Time.instant

    def initialize(@store : Store, @sample : Float64 = 1.0, capacity : Int32 = 4096, @batch : Int32 = 256,
                   @flush : Time::Span = 10.seconds)
      raise ArgumentError.new("sample must be between 0 and 1") unless 0.0 <= sample <= 1.0
      @events = Channel(Trace::Span).new(capacity)
      spawn(name: "punch-ops-sink") { drain }
    end

    def emit(event : Trace::Span) : Nil
      select
      when @events.send(event)
      else
        @dropped.add(1, :relaxed)
      end
    rescue Channel::ClosedError
    end

    # Writes what is waiting, then stops.
    def close : Nil
      return if @events.closed?

      @events.close
      @done.receive
    end

    # Events dropped because the sink was full, since it started.
    def dropped : Int64
      @dropped.get(:relaxed)
    end

    # What *event* leaves in `ops.db`, or `nil` for nothing.
    def capture(event : Trace::Span) : Capture?
      Sink.capture(event, sample, slow: admit_slow?(event))
    end

    # :ditto:
    def self.capture(event : Trace::Span, sample : Float64 = 1.0, slow : Bool = Sink.slow?(event)) : Capture?
      raised = event.exceptions
      failed = event.status.error?
      kind = kind(event)
      events = event["punch.events"]?.as?(Array(String)) || [] of String
      sampled = sampled?(event, sample)
      keep = keep?(kind, failed || !raised.empty?, sampled, slow)
      kept_events = sampled || keep ? events : [] of String
      return if !keep && kept_events.empty?

      fields = keep ? String.build { |io| Trace::JSONEvents.write(io, event) } : ""
      Capture.new(at: event.start_time, kind: kind, name: event.name, trace_id: event.trace_id.try(&.to_s),
        duration_ms: event.duration.try(&.total_milliseconds.round(3)), failed: failed,
        job_id: kind == "job" ? event["messaging.message.id"]?.as?(String).try(&.to_i64?) : nil,
        fields: fields, keep: keep, raised: raised.map { |item| error(item) }, events: kept_events)
    end

    # Whether the wide event itself is kept: when it failed or raised, is
    # a report, is a sampled job run, or is a slow request.
    private def self.keep?(kind : String, failed : Bool, sampled : Bool, slow : Bool) : Bool
      failed || kind == "other" || (kind == "job" && sampled) || slow
    end

    # Whether *event* is a successful request that took `Ops.slow` or
    # longer.
    def self.slow?(event : Trace::Span) : Bool
      return false unless event.kind.server?
      return false if event.status.error?

      duration = event.duration || return false
      duration >= Ops.slow
    end

    # What *event* adds to the stats: its own run, by its name, and each
    # named query it ran.
    def self.tallies(event : Trace::Span) : Tallies
      Tallies.new.tap { |tallies| tally(event, tallies) }
    end

    # :ditto:
    def self.tally(event : Trace::Span, tallies : Tallies) : Nil
      kind = kind(event)
      return if kind == "other"

      bucket = Ops.bucket(event.start_time)
      if duration = event.duration
        tally = tallies[{kind, event.name, bucket}] ||= Tally.new
        tally.run(duration.total_milliseconds, event.status.error?)
        tally.wait_ms += number(event["punch.db.writer_wait_ms"]?)
        tally.db_ms += number(event["punch.db.duration_ms"]?)
        tally.queries += number(event["punch.db.queries"]?).to_i64
        tally.replays += 1 if event["punch.idempotency"]? == "replayed"
      end
      event.queries.each do |name, query|
        (tallies[{"query", name, bucket}] ||= Tally.new).add(query)
      end
    end

    private def self.number(value : Trace::Value?) : Float64
      case value
      when Int64, Float64 then value.to_f64
      else                     0.0
      end
    end

    # A slow request, if the cap of its route and bucket leaves room.
    private def admit_slow?(event : Trace::Span) : Bool
      return false unless Sink.slow?(event)

      key = {event.name, Ops.bucket(event.start_time)}
      kept = @slow_kept[key]? || 0
      return false if kept >= SLOW_PER_BUCKET

      @slow_kept[key] = kept + 1
      true
    end

    # `request`, `job`, or `other` (a report).
    private def self.kind(event : Trace::Span) : String
      case event.kind
      when .server?   then "request"
      when .consumer? then "job"
      else                 "other"
      end
    end

    private def self.error(raised : Trace::Raised) : RaisedError
      exception = raised.exception
      RaisedError.new(Ops.fingerprint(exception, raised.source), exception.class.name, raised.source,
        Ops.cut(exception.message, Store::MAX_MESSAGE), Ops.cut(exception.backtrace?.try(&.join('\n')), Store::MAX_BACKTRACE))
    end

    private def self.sampled?(event : Trace::Span, sample : Float64) : Bool
      return true if sample >= 1.0
      return false if sample <= 0.0

      id = event.trace_id || return true
      id.low / 2.0**64 < sample
    end

    private def drain : Nil
      batch = [] of Capture
      loop do
        select
        when event = @events.receive?
          break unless event
          add(batch, event)
          while batch.size < @batch && (more = waiting)
            add(batch, more)
          end
          write(batch)
          batch.clear
        when timeout(@flush)
        end
        flush if Time.instant - @flushed >= @flush
      end
    ensure
      flush
      @done.send(nil)
    end

    private def add(batch : Array(Capture), event : Trace::Span) : Nil
      Sink.tally(event, @tallies)
      capture(event).try { |capture| batch << capture }
    rescue ex
      Log.error(exception: ex) { "ops sink could not read #{event.name}" }
    end

    # Writes the stats added up since the last time.
    private def flush : Nil
      @flushed = Time.instant
      unless @slow_kept.empty?
        current = Ops.bucket(Time.utc)
        @slow_kept.reject! { |(_, bucket), _| bucket < current }
      end
      return if @tallies.empty?

      tallies, @tallies = @tallies, Tallies.new
      @store.store(tallies)
    rescue ex
      Log.error(exception: ex) { "ops sink could not write the stats" }
    end

    private def write(batch : Array(Capture)) : Nil
      @store.store(batch)
      if (dropped = self.dropped) > @reported
        Log.warn { "ops sink was full: #{dropped - @reported} wide event(s) not recorded in ops.db" }
        @reported = dropped
      end
    rescue ex
      Log.error(exception: ex) { "ops sink could not write #{batch.size} record(s)" }
    end

    private def waiting : Trace::Span?
      select
      when event = @events.receive?
        event
      else
        nil
      end
    end
  end

  # Removes ops history past the retention window, every hour
  # (`Punch::Ops.retention`). Does nothing where ops recording is off.
  @[Punch::Job::Recurring(every: 1.hour)]
  struct Purge
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      store = Ops.current? || return
      removed = store.purge(Time.utc - Ops.retention)
      Trace.event.set("punch.ops.purged", removed) if Trace.event.recording?
      nil
    end
  end
end
