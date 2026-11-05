module Punch::Trace
  # An attribute value. Domain types are converted where they are set, so a
  # `Punch::Secret` never becomes one: passing it does not compile.
  alias Value = String | Bool | Int64 | Float64 | Array(String)

  # An exception recorded in a trace, with the name of the span it was
  # recorded in: a subscriber's, a job's, a request's.
  record Raised, source : String, exception : Exception

  # What one named query cost in one trace: how often it ran, how often it
  # failed, the time in total and at most, the rows, and the statements per
  # duration bucket (`Metrics::DURATION_BOUNDS`). The ops sink adds these up
  # per query.
  struct QueryTally
    getter count : Int32 = 0
    getter failed : Int32 = 0
    getter total_ms : Float64 = 0.0
    getter max_ms : Float64 = 0.0
    getter rows : Int64 = 0
    getter buckets = StaticArray(UInt32, 15).new(0_u32)

    def add(ms : Float64, rows : Int64, ok : Bool) : QueryTally
      copy = self
      copy.record(ms, rows, ok)
      copy
    end

    protected def record(ms : Float64, rows : Int64, ok : Bool) : Nil
      @count += 1
      @failed += 1 unless ok
      @total_ms += ms
      @max_ms = ms if ms > @max_ms
      @rows += rows
      @buckets[QueryTally.bucket(ms)] += 1
    end

    # The bucket of a duration in milliseconds: (previous bound, bound], as
    # `Metrics::Histogram` counts.
    def self.bucket(ms : Float64) : Int32
      seconds = ms / 1000
      Metrics::DURATION_BOUNDS.bsearch_index { |bound| bound >= seconds } || Metrics::DURATION_BOUNDS.size
    end
  end

  # OpenTelemetry's span kinds, as far as Punch uses them.
  enum Kind
    Internal
    Server
    Client
    # Processing a message, such as a job.
    Consumer
  end

  enum Status
    Unset
    Ok
    Error
  end

  # One timed piece of work in a trace. The root span of a request is also
  # its wide event: its attributes, plus the totals that child spans add to
  # it, are what `EventSink`s emit.
  #
  # A span is safe to use from several fibers. Finishing it twice does
  # nothing.
  #
  # `Span::NOOP` stands for "not recording": with tracing off, or below a
  # trace that is not sampled. Everything on it does nothing and allocates
  # nothing, so instrumented code never checks.
  class Span
    NOOP = new

    getter name : String
    getter kind : Kind
    getter parent_id : SpanID?
    # When the span started, on the monotonic clock.
    getter started : Time::Instant
    getter status : Status = Status::Unset
    getter status_message : String?
    @span_id : SpanID
    @duration : Time::Span?
    @attributes : Hash(String, Value)?
    @recording : Recording?

    private def initialize
      @name = ""
      @kind = Kind::Internal
      @span_id = SpanID.new(1)
      @started = Time.instant
    end

    # :nodoc:
    def initialize(@recording : Recording, @name : String, @kind : Kind, @span_id : SpanID, @parent_id : SpanID?)
      @started = Time.instant
    end

    def recording? : Bool
      !@recording.nil?
    end

    def trace_id : TraceID?
      @recording.try(&.trace_id)
    end

    def span_id : SpanID?
      @span_id if recording?
    end

    # This span's IDs for a `traceparent` header, or `nil` if not recording.
    def span_context : SpanContext?
      recording = @recording || return
      SpanContext.new(recording.trace_id, @span_id, recording.sampled?)
    end

    # The request's root span: the wide event.
    def root : Span
      @recording.try(&.root) || self
    end

    def root? : Bool
      root.same?(self)
    end

    # Whether the trace's spans are exported. The root always records for
    # the wide event; its children only when sampled.
    def sampled? : Bool
      @recording.try(&.sampled?) || false
    end

    # `nil` until finished.
    def duration : Time::Span?
      @duration
    end

    def finished? : Bool
      !@duration.nil?
    end

    # When the span started, by the wall clock: the root's start plus the
    # monotonic offset, so the spans of one trace never go backwards.
    def start_time : Time
      recording = @recording || return Time::UNIX_EPOCH
      recording.start_time + (@started - recording.root.started)
    end

    def name=(name : String) : Nil
      synchronize { @name = name }
    end

    # Sets an attribute. Use OpenTelemetry's names where one exists
    # (`http.route`, `db.namespace`), `punch.` for Punch's own, and the
    # app's own prefix for business fields (`invoice.id`).
    def set(key : String, value : Value) : Nil
      synchronize { attributes_for_write[key] = value }
    end

    def set(key : String, value : Int::Primitive) : Nil
      set(key, value.to_i64)
    end

    def set(key : String, value : Float32) : Nil
      set(key, value.to_f64)
    end

    def set(key : String, value : Symbol) : Nil
      set(key, value.to_s)
    end

    def set(key : String, value : Secret(T)) : Nil forall T
      {% raise "A Punch::Secret cannot be a span attribute: spans are exported and logged (lib/punch/docs/tracing.md). Record something that is not secret, such as the key ID." %}
    end

    def []=(key : String, value) : Nil
      set(key, value)
    end

    def [](key : String) : Value
      self[key]? || raise KeyError.new("no span attribute #{key}")
    end

    def []?(key : String) : Value?
      synchronize { @attributes.try(&.[key]?) }
    end

    # Adds *amount* to a numeric attribute, starting from zero: the totals
    # of a wide event, such as `punch.db.queries`.
    def add(key : String, amount : Int64 | Float64) : Nil
      synchronize { add_unlocked(key, amount) }
    end

    def add(key : String, amount : Int32) : Nil
      add(key, amount.to_i64)
    end

    # Appends *value* to a list attribute, keeping at most *limit*
    # entries: `punch.events` on the wide event.
    def append(key : String, value : String, limit : Int32 = 100) : Nil
      synchronize do
        attributes = attributes_for_write
        list = attributes[key]?.as?(Array(String)) || (attributes[key] = [] of String).as(Array(String))
        list << value if list.size < limit
      end
    end

    # Several `add`s under one lock: `add({"punch.db.queries", 1_i64}, {"punch.db.rows", 20_i64})`.
    def add(*pairs : {String, Int64 | Float64}) : Nil
      synchronize { pairs.each { |key, amount| add_unlocked(key, amount) } }
    end

    private def add_unlocked(key : String, amount : Int64 | Float64) : Nil
      attributes = attributes_for_write
      current = attributes[key]?
      attributes[key] = case current
                        when Int64   then amount.is_a?(Int64) ? current + amount : current + amount.to_f64
                        when Float64 then current + amount
                        else              amount
                        end
    end

    # Yields each attribute while holding the span's lock: do not touch the
    # span from the block.
    def each_attribute(& : String, Value ->) : Nil
      synchronize { @attributes.try &.each { |key, value| yield key, value } }
    end

    # A copy of the attributes.
    def attributes : Hash(String, Value)
      synchronize { @attributes.try(&.dup) } || {} of String => Value
    end

    # Marks the span as failed by *exception*, with OpenTelemetry's
    # `exception.type` and `exception.message`, and records it for the
    # trace (`record_exception`). The message comes from Punch's own
    # errors, which leave values out, or from the app's.
    def error(exception : Exception) : Nil
      synchronize do
        attributes = attributes_for_write
        attributes["exception.type"] = exception.class.name
        exception.message.try { |message| attributes["exception.message"] = message }
        @status = Status::Error
        @status_message = exception.class.name
      end
      record_exception(exception)
    end

    # Keeps *exception* with its backtrace for the trace's wide event
    # (`exceptions`), where the ops sink groups it, without failing the
    # span: OpenTelemetry's `RecordException`. *source* names where it was
    # handled, this span's name by default. The same exception is kept once,
    # however many spans it passes through, with the source of the last one
    # to record it: the request or job it reached, or the subscriber that
    # swallowed it.
    def record_exception(exception : Exception, source : String = @name) : Nil
      @recording.try(&.raised(Raised.new(source, exception)))
    end

    # The exceptions recorded anywhere in this span's trace, first first.
    def exceptions : Array(Raised)
      @recording.try(&.exceptions) || [] of Raised
    end

    # Counts one run of the named query *name* for the trace, sampled or
    # not; kept beside the attributes, never exported or logged.
    def tally_query(name : String, ms : Float64, rows : Int64, ok : Bool) : Nil
      @recording.try(&.tally_query(name, ms, rows, ok))
    end

    # The named queries this span's trace ran, by name.
    def queries : Hash(String, QueryTally)
      @recording.try(&.queries) || {} of String => QueryTally
    end

    # Marks the span as failed, with a short reason such as an error code.
    def error(message : String) : Nil
      synchronize do
        @status = Status::Error
        @status_message = message
      end
    end

    def ok : Nil
      synchronize { @status = Status::Ok }
    end

    # Starts a child span. Below a trace that is not sampled, or past the
    # limit of spans per trace, the child is `NOOP`.
    def child(name : String, kind : Kind = Kind::Internal) : Span
      recording = @recording || return NOOP
      recording.child(name, kind, @span_id)
    end

    # Runs the block in a child span that is current for its length, and
    # finishes it. An exception marks it failed and is raised again.
    def span(name : String, kind : Kind = Kind::Internal, & : Span -> T) : T forall T
      child = child(name, kind)
      begin
        Trace.with(child) { yield child }
      rescue ex
        child.error(ex)
        raise ex
      ensure
        child.finish
      end
    end

    # Ends the span. Finishing the root ends the trace: the wide event is
    # emitted and, if sampled, the spans are exported. A second call does
    # nothing.
    def finish : Nil
      recording = @recording || return
      synchronize do
        return if @duration

        @duration = Time.instant - @started
      end
      recording.finished(self)
    end

    # The span's name and timing; never its attributes.
    def inspect(io : IO) : Nil
      io << "#<Punch::Trace::Span " << @name
      @duration.try { |duration| io << ' ' << duration.total_milliseconds.round(3) << " ms" }
      io << '>'
    end

    private def attributes_for_write : Hash(String, Value)
      # Sized for a request's wide event, which sets about fifteen.
      @attributes ||= Hash(String, Value).new(initial_capacity: 16)
    end

    private def synchronize(&)
      if recording = @recording
        recording.lock.synchronize { yield }
      end
    end
  end

  # The state of one trace: its root, the finished spans, and the IDs.
  # :nodoc:
  class Recording
    # Spans recorded per trace. Past it, children are `NOOP`; the totals on
    # the root still count, and `punch.trace.dropped_spans` says how many.
    MAX_SPANS = 1024

    # Weyl sequence step: consecutive span IDs differ in every byte.
    STEP = 0x9E3779B97F4A7C15_u64

    getter lock = Mutex.new(:unchecked)
    getter trace_id : TraceID
    getter? sampled : Bool
    getter start_time : Time
    getter! root : Span
    getter tracer : Tracer
    @seed : UInt64
    @counter = Atomic(UInt64).new(0)
    @spans = [] of Span
    @dropped = 0
    @raised : Array(Raised)?
    @queries : Hash(String, QueryTally)?

    def initialize(@tracer : Tracer, @trace_id : TraceID, @seed : UInt64, @sampled : Bool)
      @start_time = Time.utc
    end

    def start_root(name : String, kind : Kind, parent_id : SpanID?) : Span
      @root = Span.new(self, name, kind, next_id, parent_id)
    end

    def child(name : String, kind : Kind, parent_id : SpanID) : Span
      return Span::NOOP unless sampled?

      full = lock.synchronize do
        if @spans.size + @dropped >= MAX_SPANS - 1
          @dropped += 1
          true
        else
          false
        end
      end
      full ? Span::NOOP : Span.new(self, name, kind, next_id, parent_id)
    end

    def finished(span : Span) : Nil
      if span.same?(root)
        spans = lock.synchronize { @spans.dup }
        root.set("punch.trace.dropped_spans", @dropped) if @dropped > 0
        @tracer.finished(root, spans)
      else
        lock.synchronize { @spans << span }
      end
    end

    def raised(raised : Raised) : Nil
      lock.synchronize do
        list = @raised ||= [] of Raised
        if index = list.index(&.exception.same?(raised.exception))
          list[index] = raised
        else
          list << raised
        end
      end
    end

    def exceptions : Array(Raised)
      lock.synchronize { @raised.try(&.dup) } || [] of Raised
    end

    # Named queries per trace past which further names are not counted.
    MAX_QUERIES = 256

    def tally_query(name : String, ms : Float64, rows : Int64, ok : Bool) : Nil
      lock.synchronize do
        tallies = @queries ||= {} of String => QueryTally
        if tally = tallies[name]?
          tallies[name] = tally.add(ms, rows, ok)
        elsif tallies.size < MAX_QUERIES
          tallies[name] = QueryTally.new.add(ms, rows, ok)
        end
      end
    end

    def queries : Hash(String, QueryTally)
      lock.synchronize { @queries.try(&.dup) } || {} of String => QueryTally
    end

    private def next_id : SpanID
      value = @seed &+ @counter.add(1, :relaxed) &* STEP
      SpanID.new(value.zero? ? STEP : value)
    end
  end
end
