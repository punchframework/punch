module Punch::OTLP
  # Sends sampled traces to an OTLP/HTTP receiver. `export` only queues: a
  # request never waits for the network. A fiber sends a batch once it holds
  # *batch_spans* spans or its first trace waited *delay*. When *capacity*
  # traces are queued, further ones are dropped and counted
  # (`punch.otlp.spans` with `punch.otlp.outcome: dropped`), and so are
  # batches the receiver refuses or that cannot be sent in time. `close`
  # (the tracer's, at shutdown) sends what is queued, within the request
  # timeout.
  #
  # ```
  # tracer = Punch::Trace::Tracer.new(exporters: [Punch::OTLP::TraceExporter.new(config)] of Punch::Trace::Exporter)
  # ```
  class TraceExporter < Trace::Exporter
    @queue : Channel(Trace::Finished)
    @done = Channel(Nil).new
    @exported = Atomic(Int64).new(0)
    @dropped = Atomic(Int64).new(0)

    def initialize(@config : Config, *, url : URI? = config.traces, capacity : Int32 = 2048,
                   @batch_spans : Int32 = 512, @delay : Time::Span = 5.seconds,
                   registry : Metrics::Registry = Metrics.registry)
      raise ArgumentError.new("no traces endpoint configured") unless url
      @queue = Channel(Trace::Finished).new(capacity)
      @sender = Sender.new(url, config.headers, config.timeout)
      registry.observe("punch.otlp.spans", :counter, "{span}", "Spans sent to the OTLP receiver, and spans dropped") do |recorder|
        recorder.record(@exported.get, Metrics::Attributes{"punch.otlp.outcome" => "exported"})
        recorder.record(@dropped.get, Metrics::Attributes{"punch.otlp.outcome" => "dropped"})
      end
      spawn(name: "punch-otlp-traces") { drain }
    end

    def export(trace : Trace::Finished) : Nil
      select
      when @queue.send(trace)
      else
        @dropped.add(trace.spans.size + 1)
      end
    rescue Channel::ClosedError
      @dropped.add(trace.spans.size + 1)
    end

    # Spans sent and spans dropped so far.
    def counts : {Int64, Int64}
      {@exported.get, @dropped.get}
    end

    def close : Nil
      return if @queue.closed?

      @sender.hurry
      @queue.close
      @done.receive
    end

    private def drain : Nil
      batch = [] of Trace::Finished
      spans = 0
      since = nil.as(Time::Instant?)
      loop do
        wait = since ? Math.max(@delay - (Time.instant - since), Time::Span.zero) : 1.hour
        select
        when trace = @queue.receive?
          break unless trace
          batch << trace
          spans += trace.spans.size + 1
          since ||= Time.instant
          next if spans < @batch_spans
        when timeout(wait)
          next if batch.empty?
        end
        send(batch, spans, Time.instant + @delay * 6)
        batch = [] of Trace::Finished
        spans = 0
        since = nil
      end
      send(batch, spans, Time.instant + @config.timeout) unless batch.empty?
    ensure
      @sender.close
      @done.send(nil)
    end

    private def send(batch : Array(Trace::Finished), spans : Int32, deadline : Time::Instant) : Nil
      body = String.build { |io| Encode.traces(io, @config.resource, batch) }
      (@sender.post(body, deadline) ? @exported : @dropped).add(spans)
    rescue ex
      @dropped.add(spans)
      Sender::Log.error(exception: ex) { "exporting #{spans} spans failed" }
    end
  end

  # Sends the metrics of a registry to an OTLP/HTTP receiver every
  # *interval* (`OTEL_METRIC_EXPORT_INTERVAL`), and once more on `stop`.
  # Counters and histograms are cumulative, so a lost export loses
  # resolution, not counts.
  class MetricExporter
    @stop = Channel(Nil).new
    @done = Channel(Nil).new
    @running = false

    def initialize(@config : Config, @registry : Metrics::Registry = Metrics.registry, *, url : URI? = config.metrics,
                   @interval : Time::Span = config.metric_interval)
      raise ArgumentError.new("no metrics endpoint configured") unless url
      @sender = Sender.new(url, config.headers, config.timeout)
    end

    def start : Nil
      return if @running

      @running = true
      spawn(name: "punch-otlp-metrics") { run }
    end

    # Sends once more and stops. Call it before the databases close, so
    # their last values are in.
    def stop : Nil
      return unless @running

      @running = false
      @sender.hurry
      @stop.send(nil)
      @done.receive
    end

    # Collects and sends now. Whether the receiver took it; `true` when
    # there was nothing to send.
    def export(deadline : Time::Instant = Time.instant + @interval) : Bool
      series = @registry.collect
      return true if series.empty?

      body = String.build { |io| Encode.metrics(io, @config.resource, series) }
      @sender.post(body, deadline)
    rescue ex
      Sender::Log.error(exception: ex) { "exporting metrics failed" }
      false
    end

    private def run : Nil
      loop do
        select
        when @stop.receive
          break
        when timeout(@interval)
          export
        end
      end
      export(Time.instant + @config.timeout)
    ensure
      @sender.close
      @done.send(nil)
    end
  end
end
