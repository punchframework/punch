# Metrics: instruments on the OpenTelemetry data model, read
# when someone collects them. Details in `docs/metrics.md`.
#
# Punch's own signals are observed, not pushed: a source registers a
# callback per instrument, and `Registry#collect` asks every callback for
# its current values. Nothing is computed between collections, so an
# instrument nobody collects costs nothing but the counters behind it.
module Punch::Metrics
  alias Value = String | Bool | Int64 | Float64
  alias Attributes = Hash(String, Value)

  enum Kind
    # The current value, such as a queue's depth.
    Gauge
    # A monotonic total since the instrument began.
    Counter
    # A distribution since the instrument began, in explicit buckets.
    Histogram
  end

  # Durations in seconds, from half a millisecond to ten seconds: the
  # buckets OpenTelemetry's semantic conventions advise for durations,
  # with three finer ones below 5 ms for SQLite's fast work.
  DURATION_BOUNDS = [0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

  # A distribution as collected: the count per bucket (one more than
  # bounds: the last counts values above the last bound), and the total,
  # the smallest, and the largest value recorded.
  struct Distribution
    getter bounds : Array(Float64)
    getter counts : Array(UInt64)
    getter count : UInt64
    getter sum : Float64
    getter min : Float64
    getter max : Float64

    def initialize(@bounds : Array(Float64), @counts : Array(UInt64), @count : UInt64, @sum : Float64,
                   @min : Float64, @max : Float64)
    end
  end

  # Records values into buckets, from any thread. A histogram is held by
  # the code that measures, and read by its source's callback.
  class Histogram
    getter bounds : Array(Float64)

    def initialize(@bounds : Array(Float64) = DURATION_BOUNDS)
      raise ArgumentError.new("bounds must be ascending") unless @bounds.each_cons_pair.all? { |low, high| low < high }
      @counts = Array(UInt64).new(@bounds.size + 1, 0_u64)
      @count = 0_u64
      @sum = 0.0
      @min = Float64::INFINITY
      @max = -Float64::INFINITY
      @lock = Mutex.new
    end

    def record(value : Float64) : Nil
      # A value on a bound counts in the bucket that bound closes, as in
      # OpenTelemetry: (previous bound, bound].
      index = @bounds.bsearch_index { |bound| bound >= value } || @bounds.size
      @lock.synchronize do
        @counts[index] += 1
        @count += 1
        @sum += value
        @min = value if value < @min
        @max = value if value > @max
      end
    end

    def snapshot : Distribution
      @lock.synchronize { Distribution.new(@bounds, @counts.dup, @count, @sum, @min, @max) }
    end

    def count : UInt64
      @lock.synchronize { @count }
    end
  end

  # One value of an instrument, for one set of attributes.
  struct Point
    getter attributes : Attributes
    getter value : Int64 | Float64 | Distribution

    def initialize(@attributes : Attributes, @value : Int64 | Float64 | Distribution)
    end
  end

  # What one instrument held when it was collected. `start` is when the
  # instrument began counting (counters and histograms are cumulative from
  # there), `time` when it was collected.
  struct Series
    getter name : String
    getter kind : Kind
    getter unit : String
    getter description : String
    getter points : Array(Point)
    getter start : Time
    getter time : Time

    def initialize(@name : String, @kind : Kind, @unit : String, @description : String, @points : Array(Point),
                   @start : Time, @time : Time)
    end
  end

  # Handed to an instrument's callback while it is collected.
  class Recorder
    getter points = [] of Point

    def record(value : Int | Float | Distribution, attributes : Attributes) : Nil
      value = value.to_i64 if value.is_a?(Int)
      value = value.to_f64 if value.is_a?(Float)
      @points << Point.new(attributes, value)
    end
  end

  alias Callback = Recorder -> Nil

  # :nodoc:
  class Instrument
    getter name : String
    getter kind : Kind
    getter unit : String
    getter description : String
    getter callbacks = [] of Callback
    getter start : Time = Time.utc

    def initialize(@name : String, @kind : Kind, @unit : String, @description : String)
    end
  end

  # The instruments of a process. Each name is one instrument, however many
  # sources report into it: every database registers its own callback for
  # `punch.db.wal.size`, told apart by `db.namespace`.
  #
  # ```
  # registry = Punch::Metrics::Registry.new
  # registry.observe("app.queue.depth", :gauge, "{job}", "Jobs waiting") do |recorder|
  #   recorder.record(queue.size, {"queue" => "default"} of String => Punch::Metrics::Value)
  # end
  # registry.collect # => [Series(app.queue.depth, …)]
  # ```
  class Registry
    def initialize
      @instruments = {} of String => Instrument
      @lock = Mutex.new
    end

    # Adds *callback* to the instrument *name*, creating it. Registering a
    # name again with another kind or unit raises.
    def observe(name : String, kind : Kind, unit : String, description : String, &callback : Callback) : Nil
      raise ArgumentError.new("invalid metric name: #{name.inspect}") unless name.matches?(/\A[a-z][a-z0-9_.]*\z/)
      @lock.synchronize do
        instrument = @instruments[name] ||= Instrument.new(name, kind, unit, description)
        unless instrument.kind == kind && instrument.unit == unit
          raise ArgumentError.new("metric #{name} is a #{instrument.kind} in #{instrument.unit}, not a #{kind} in #{unit}")
        end
        instrument.callbacks << callback
      end
    end

    # Every instrument with at least one point, by name. A callback that
    # raises is logged and skipped; the others are still collected.
    def collect : Array(Series)
      instruments = @lock.synchronize { @instruments.values.map { |instrument| {instrument, instrument.callbacks.dup} } }
      time = Time.utc
      instruments.compact_map do |(instrument, callbacks)|
        recorder = Recorder.new
        callbacks.each do |callback|
          callback.call(recorder)
        rescue ex
          ::Log.for("punch.metrics").error(exception: ex) { "collecting #{instrument.name} failed" }
        end
        next if recorder.points.empty?
        Series.new(instrument.name, instrument.kind, instrument.unit, instrument.description, recorder.points,
          instrument.start, time)
      end.sort_by!(&.name)
    end

    # Names of the registered instruments.
    def names : Array(String)
      @lock.synchronize { @instruments.keys.sort! }
    end
  end

  @@registry = Registry.new

  # The process's registry: `serve` and `jobs` register their databases
  # here, and the exporter (`docs/metrics.md`) reads it.
  def self.registry : Registry
    @@registry
  end
end
