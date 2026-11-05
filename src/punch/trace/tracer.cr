require "json"
require "log"

module Punch::Trace
  # A finished trace: its root and the other recorded spans, in the order
  # they finished.
  struct Finished
    getter root : Span
    getter spans : Array(Span)

    def initialize(@root : Span, @spans : Array(Span))
    end

    # The root first, then the others.
    def each_span(& : Span ->) : Nil
      yield root
      spans.each { |span| yield span }
    end

    # The first span named *name*.
    def [](name : String) : Span
      self[name]? || raise KeyError.new("no span named #{name}")
    end

    # The first span named *name*, or `nil`.
    def []?(name : String) : Span?
      return root if root.name == name

      spans.find { |span| span.name == name }
    end
  end

  # Receives every sampled trace when its root finishes, in the fiber that
  # finished it: an exporter that does I/O should hand the trace to a fiber
  # of its own. The console exporter writes directly; it is for development.
  abstract class Exporter
    abstract def export(trace : Finished) : Nil

    # Writes out what is buffered; called once at shutdown.
    def close : Nil
    end
  end

  # Receives every wide event: the root span of each request and of each
  # job, sampled or not. `event.exceptions` holds what was raised in the
  # trace (`Span#record_exception`).
  abstract class EventSink
    abstract def emit(event : Span) : Nil

    # Writes out what is buffered; called once at shutdown.
    def close : Nil
    end
  end

  # Starts traces and passes finished ones on.
  #
  # ```
  # tracer = Punch::Trace::Tracer.new(exporters: [Punch::Trace::ConsoleExporter.new] of Punch::Trace::Exporter)
  # server = Punch::HTTP::Server.new(config, tracer) { |context| router.call(context) }
  # ```
  #
  # The default writes each wide event as a JSON line to stdout
  # (`JSONEvents`) and exports no spans; with no exporter, child spans are
  # not even recorded. `Tracer.off` turns telemetry off: no spans, no wide
  # events.
  class Tracer
    Log = ::Log.for("punch.trace")

    getter exporters : Array(Exporter)
    getter events : Array(EventSink)
    # The share of traces whose spans are recorded and exported, decided by
    # trace ID, so the same trace gets the same decision in every service.
    # A sampled remote parent wins.
    getter sample_ratio : Float64
    getter? enabled : Bool

    def initialize(*, @exporters : Array(Exporter) = [] of Exporter,
                   @events : Array(EventSink) = [JSONEvents.new] of EventSink,
                   @sample_ratio : Float64 = 1.0, @enabled : Bool = true)
      raise ArgumentError.new("sample_ratio must be between 0 and 1") unless 0.0 <= sample_ratio <= 1.0
    end

    # Telemetry off: every span is `Span::NOOP`.
    def self.off : Tracer
      new(events: [] of EventSink, enabled: false)
    end

    # Starts a trace, continuing *parent* when given.
    def start(name : String, kind : Kind = Kind::Server, parent : SpanContext? = nil) : Span
      return Span::NOOP unless enabled?

      random = uninitialized StaticArray(UInt8, 24)
      Random::Secure.random_bytes(random.to_slice)
      trace_id = parent.try(&.trace_id) || TraceID.new(StaticArray(UInt8, 16).new { |index| random[index] })
      seed = IO::ByteFormat::BigEndian.decode(UInt64, random.to_slice[16, 8])
      sampled = !exporters.empty? && (parent ? parent.sampled? : sample?(trace_id))
      Recording.new(self, trace_id, seed, sampled).start_root(name, kind, parent.try(&.span_id))
    end

    # Reports *exception* raised outside any trace, such as in a worker's
    # loop, as a failed trace of its own named *name*: it reaches every
    # sink, so the ops console lists it with the errors of requests and
    # jobs.
    def report(exception : Exception, name : String) : Nil
      span = start(name, :internal)
      span.error(exception)
      span.finish
    end

    # Closes every sink and exporter, so buffered events are written. The
    # server calls it last in its shutdown.
    def close : Nil
      events.each(&.close)
      exporters.each(&.close)
    end

    private def sample?(trace_id : TraceID) : Bool
      return true if sample_ratio >= 1.0
      return false if sample_ratio <= 0.0

      trace_id.low / 2.0**64 < sample_ratio
    end

    # :nodoc:
    def finished(root : Span, spans : Array(Span)) : Nil
      events.each do |sink|
        sink.emit(root)
      rescue ex
        Log.error(exception: ex) { "event sink #{sink.class} failed" }
      end
      return unless root.sampled?

      trace = Finished.new(root, spans)
      exporters.each do |exporter|
        exporter.export(trace)
      rescue ex
        Log.error(exception: ex) { "exporter #{exporter.class} failed" }
      end
    end
  end

  # The fields of a wide event: the root's attributes, its IDs and
  # duration, and `error` with the status message when it failed. Totals in
  # milliseconds are rounded to microseconds.
  def self.event_fields(event : Span) : Hash(String, Value)
    fields = {} of String => Value
    event_header(event) { |key, value| fields[key] = value }
    event.each_attribute { |key, value| fields[key] = value.is_a?(Float64) ? value.round(3) : value }
    fields
  end

  # The fields of a wide event that are not attributes.
  # :nodoc:
  def self.event_header(event : Span, & : String, Value ->) : Nil
    yield "name", event.name
    event.trace_id.try { |id| yield "trace_id", id.to_s }
    event.span_id.try { |id| yield "span_id", id.to_s }
    event.duration.try { |duration| yield "duration_ms", duration.total_milliseconds.round(3) }
    event.status_message.try { |message| yield "error", message } if event.status.error?
  end

  # Wide events as entries of the `punch.request` log at info level: the
  # name as the message, the fields under the metadata key `event` (log
  # metadata keys are symbols, which cannot be made at run time). For apps
  # that send everything through `Log`; it cost 30% of the throughput at
  # full load, `JSONEvents` about nothing.
  class LogEvents < EventSink
    Log = ::Log.for("punch.request")

    def emit(event : Span) : Nil
      Log.info &.emit(event.name, event: Trace.event_fields(event))
    end
  end

  # Wide events as JSON lines, one object per event with the fields at the
  # top level and `time` first: for log shippers in production.
  #
  # Requests hand the finished root span to one writer fiber, which
  # serializes, writes, and flushes in batches. Measured at full load: a
  # lock and a flush per request cost a quarter of the throughput; a thread
  # of its own instead of a fiber cost 15%. When *capacity* events are
  # waiting, requests wait rather than lose events. `close` writes what is
  # left.
  class JSONEvents < EventSink
    @events : Channel(Span)
    @done = Channel(Nil).new

    def initialize(@io : IO = STDOUT, capacity : Int32 = 4096)
      @events = Channel(Span).new(capacity)
      spawn(name: "punch-json-events") { drain }
    end

    def emit(event : Span) : Nil
      @events.send(event)
    rescue Channel::ClosedError
      Tracer::Log.warn { "wide event after JSONEvents#close: #{event.name}" }
    end

    def close : Nil
      return if @events.closed?

      @events.close
      @done.receive
    end

    # One event as a JSON object, without the newline. Written by hand:
    # `JSON::Builder` escapes character by character and cost 2 µs for a
    # typical event, about half of it avoidable.
    def self.write(io : IO, event : Span) : Nil
      io << %({"time":")
      event.start_time.to_rfc3339(io, fraction_digits: 6)
      io << %(","name":)
      string(io, event.name)
      event.trace_id.try { |id| io << %(,"trace_id":") << id << '"' }
      event.span_id.try { |id| io << %(,"span_id":") << id << '"' }
      event.duration.try { |duration| io << %(,"duration_ms":) << duration.total_milliseconds.round(3) }
      if event.status.error? && (message = event.status_message)
        io << %(,"error":)
        string(io, message)
      end
      event.each_attribute { |key, value| field(io, key, value) }
      io << '}'
    end

    private def self.field(io : IO, key : String, value : Value) : Nil
      io << ','
      string(io, key)
      io << ':'

      case value
      in String then string(io, value)
      in Int64  then io << value
      in Bool   then io << value
      in Float64
        value.finite? ? (io << value.round(3)) : (io << "null")
      in Array(String)
        io << '['
        value.each_with_index do |item, index|
          io << ',' if index > 0
          string(io, item)
        end
        io << ']'
      end
    end

    # Copies the bytes when nothing needs escaping, which is nearly always;
    # otherwise the standard library escapes, invalid UTF-8 included.
    private def self.string(io : IO, value : String) : Nil
      plain = value.to_slice.none? { |byte| byte < 0x20 || byte == 0x22 || byte == 0x5c || byte >= 0x7f }
      if plain
        io << '"'
        io.write_string(value.to_slice)
        io << '"'
      else
        value.to_json(io)
      end
    end

    private def drain : Nil
      while event = @events.receive?
        write_line(event)
        while more = waiting_event
          write_line(more)
        end
        @io.flush
      end
    ensure
      @io.flush rescue nil
      @done.send(nil)
    end

    private def write_line(event : Span) : Nil
      JSONEvents.write(@io, event)
      @io << '\n'
    rescue ex
      Tracer::Log.error(exception: ex) { "JSONEvents could not write #{event.name}" }
    end

    private def waiting_event : Span?
      select
      when event = @events.receive?
        event
      else
        nil
      end
    end
  end

  # Keeps the last *capacity* traces in memory: for specs and, later, the
  # local trace view of the ops console.
  class MemoryExporter < Exporter
    getter capacity : Int32
    @traces = Deque(Finished).new
    @lock = Mutex.new

    def initialize(@capacity : Int32 = 1000)
    end

    def export(trace : Finished) : Nil
      @lock.synchronize do
        @traces.shift if @traces.size >= capacity
        @traces << trace
      end
    end

    def traces : Array(Finished)
      @lock.synchronize { @traces.to_a }
    end

    def clear : Nil
      @lock.synchronize { @traces.clear }
    end
  end

  # Keeps the wide events in memory, for specs.
  class MemoryEvents < EventSink
    @events = [] of Span
    @lock = Mutex.new

    def emit(event : Span) : Nil
      @lock.synchronize { @events << event }
    end

    def events : Array(Span)
      @lock.synchronize { @events.dup }
    end
  end

  # The current span of this fiber, `Span::NOOP` if there is none. Fiber-
  # scoped like the standard library's `Log.context`, never thread-local. A
  # spawned fiber starts without one; pass the span along and use `with`.
  def self.current : Span
    Fiber.current.punch_span || Span::NOOP
  end

  # Makes *span* the current span for the length of the block. A recording
  # span also makes its root the fiber's wide event, which stays reachable
  # below children that do not record (`event`).
  def self.with(span : Span, &)
    fiber = Fiber.current
    previous = fiber.punch_span
    previous_root = fiber.punch_root
    fiber.punch_span = span
    fiber.punch_root = span.root if span.recording?
    begin
      yield
    ensure
      fiber.punch_span = previous
      fiber.punch_root = previous_root
    end
  end

  # Runs the block in a new child of the current span:
  #
  # ```
  # Punch::Trace.span("charge card", :client) do |span|
  #   span["payment.provider"] = "stripe"
  #   gateway.charge(amount)
  # end
  # ```
  def self.span(name : String, kind : Kind = Kind::Internal, & : Span -> T) : T forall T
    current.span(name, kind) { |span| yield span }
  end

  # The wide event of the current request: the root span. Add the fields
  # that explain a request later, such as the IDs it acted on:
  # `Punch::Trace.event["invoice.id"] = invoice.id.to_s`.
  #
  # Below a child that does not record (a trace that is not sampled, or
  # past the span limit) this is still the root: a wide event records
  # whether or not its trace is sampled.
  def self.event : Span
    span = current
    return span.root if span.recording?

    Fiber.current.punch_root || Span::NOOP
  end
end

class Fiber
  # :nodoc:
  property punch_span : Punch::Trace::Span?
  # The wide event of the innermost recording span made current with
  # `Punch::Trace.with`.
  # :nodoc:
  property punch_root : Punch::Trace::Span?
end
