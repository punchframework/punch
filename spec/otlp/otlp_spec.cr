require "../spec_helper"
require "http/server"

# A stand-in for an OpenTelemetry collector: keeps every request, and
# answers with the statuses queued in `answers` first, then 200.
private class Receiver
  record Received, path : String, headers : ::HTTP::Headers, body : JSON::Any

  getter received = [] of Received
  @answers = Deque(Int32).new
  @lock = Mutex.new

  def initialize
    @server = ::HTTP::Server.new do |context|
      body = JSON.parse(context.request.body.try(&.gets_to_end) || "null")
      status = @lock.synchronize do
        @received << Received.new(context.request.path, context.request.headers, body)
        @answers.shift? || 200
      end
      context.response.status_code = status
      context.response.headers["Retry-After"] = "0" if status == 503
      context.response.print "{}"
    end
    @address = @server.bind_tcp("127.0.0.1", 0)
    spawn { @server.listen }
  end

  def answer(status : Int32) : Nil
    @lock.synchronize { @answers << status }
  end

  def url : String
    "http://127.0.0.1:#{@address.port}"
  end

  def snapshot : Array(Received)
    @lock.synchronize { @received.dup }
  end

  def close : Nil
    @server.close
  end
end

private def config(receiver : Receiver, **extra) : Punch::OTLP::Config
  env = {"OTEL_EXPORTER_OTLP_ENDPOINT" => receiver.url, "OTEL_SERVICE_NAME" => "invoicing",
         "OTEL_EXPORTER_OTLP_HEADERS" => "x-api-key=s3cr%3Dt"}
  extra.each { |key, value| env[key.to_s] = value }
  problems = [] of String
  config = Punch::OTLP::Config.from(env, "test", problems)
  problems.should be_empty
  config || fail "no config"
end

private def attribute(attributes : JSON::Any, key : String) : JSON::Any
  attributes.as_a.find { |pair| pair["key"] == key }.try(&.["value"]) || fail "no attribute #{key} in #{attributes.to_json}"
end

describe Punch::OTLP::Config do
  it "exports nothing without an endpoint, or when the SDK is disabled" do
    problems = [] of String
    Punch::OTLP::Config.from({} of String => String, "test", problems).should be_nil
    Punch::OTLP::Config.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "http://c:4318", "OTEL_SDK_DISABLED" => "true"}, "test", problems).should be_nil
    problems.should be_empty
  end

  it "appends each signal's path to the base, and takes a signal's own URL as it is" do
    problems = [] of String
    config = Punch::OTLP::Config.from({"OTEL_EXPORTER_OTLP_ENDPOINT"         => "https://collector:4318/otlp/",
                                       "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT" => "https://metrics.example/ingest"}, "production", problems)
    problems.should be_empty
    config = config.should_not be_nil
    config.traces.to_s.should eq("https://collector:4318/otlp/v1/traces")
    config.metrics.to_s.should eq("https://metrics.example/ingest")
    config.resource["deployment.environment.name"].should eq("production")
    config.resource["telemetry.sdk.name"].should eq("punch")
  end

  it "decodes header values and resource attributes, and never shows a header's value" do
    problems = [] of String
    config = Punch::OTLP::Config.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "http://c:4318",
                                       "OTEL_EXPORTER_OTLP_HEADERS"  => "Authorization=Bearer%20tok, x-team=a",
                                       "OTEL_RESOURCE_ATTRIBUTES"    => "service.version=1.4.0,service.name=billing"}, "test", problems)
    config = config.should_not be_nil
    config.headers.pairs.should eq([{"Authorization", "Bearer tok"}, {"x-team", "a"}])
    config.headers.inspect.should_not contain("tok")
    config.resource["service.name"].should eq("billing")
    config.resource["service.version"].should eq("1.4.0")
  end

  it "refuses headers over plain http to another machine" do
    problems = [] of String
    Punch::OTLP::Config.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "http://collector.example:4318", "OTEL_EXPORTER_OTLP_HEADERS" => "x-api-key=k"}, "production", problems)
    problems.should eq(["OTEL_EXPORTER_OTLP_HEADERS would go to collector.example over plain http: use https, or a collector on this machine"])
    problems.clear
    Punch::OTLP::Config.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "http://127.0.0.1:4318", "OTEL_EXPORTER_OTLP_HEADERS" => "x-api-key=k"}, "production", problems)
    problems.should be_empty
  end

  it "reports every problem, without echoing a header's text" do
    problems = [] of String
    Punch::OTLP::Config.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "collector:4318",
                              "OTEL_EXPORTER_OTLP_PROTOCOL" => "grpc",
                              "OTEL_EXPORTER_OTLP_HEADERS"  => "secretvalue",
                              "OTEL_METRIC_EXPORT_INTERVAL" => "soon"}, "test", problems)
    problems.size.should eq(4)
    problems.join.should_not contain("secretvalue")
    problems.join.should contain("http/json only")
  end
end

describe Punch::OTLP::TraceExporter do
  it "sends sampled traces as OTLP JSON, with the resource and the configured headers" do
    receiver = Receiver.new
    begin
      exporter = Punch::OTLP::TraceExporter.new(config(receiver), registry: Punch::Metrics::Registry.new)
      tracer = Punch::Trace::Tracer.new(exporters: [exporter] of Punch::Trace::Exporter, events: [] of Punch::Trace::EventSink)
      root = tracer.start("GET /invoices")
      root["http.response.status_code"] = 500
      root["punch.db.duration_ms"] = 1.5
      Punch::Trace.with(root) do
        root.span("Billing::Queries.invoices", :client) { |span| span["db.query.text"] = "SELECT 1" }
        root.error(RuntimeError.new("boom"))
      end
      root.finish
      tracer.close

      requests = receiver.snapshot
      requests.size.should eq(1)
      request = requests.first
      request.path.should eq("/v1/traces")
      request.headers["Content-Type"].should eq("application/json")
      request.headers["x-api-key"].should eq("s3cr=t")
      resource_spans = request.body["resourceSpans"][0]
      attribute(resource_spans["resource"]["attributes"], "service.name").should eq({"stringValue" => "invoicing"})
      resource_spans["scopeSpans"][0]["scope"]["name"].should eq("punch")
      spans = resource_spans["scopeSpans"][0]["spans"].as_a
      spans.size.should eq(2)
      server = spans.find! { |span| span["name"] == "GET /invoices" }
      client = spans.find! { |span| span["name"] == "Billing::Queries.invoices" }
      server["traceId"].as_s.should match(/\A[0-9a-f]{32}\z/)
      server["spanId"].as_s.should match(/\A[0-9a-f]{16}\z/)
      server["parentSpanId"]?.should be_nil
      client["parentSpanId"].should eq(server["spanId"])
      client["traceId"].should eq(server["traceId"])
      {server["kind"], client["kind"]}.should eq({2, 3})
      server["startTimeUnixNano"].as_s.to_i128.should be <= server["endTimeUnixNano"].as_s.to_i128
      attribute(server["attributes"], "http.response.status_code").should eq({"intValue" => "500"})
      attribute(server["attributes"], "punch.db.duration_ms").should eq({"doubleValue" => 1.5})
      attribute(client["attributes"], "db.query.text").should eq({"stringValue" => "SELECT 1"})
      server["status"].should eq({"code" => 2, "message" => "RuntimeError"})
      client["status"].should eq({"code" => 0})
      event = server["events"][0]
      event["name"].should eq("exception")
      attribute(event["attributes"], "exception.message").should eq({"stringValue" => "boom"})
      exporter.counts.should eq({2, 0})
    ensure
      receiver.close
    end
  end

  it "batches traces, retries what the receiver asks to retry, and drops what it refuses" do
    receiver = Receiver.new
    begin
      receiver.answer(503)
      registry = Punch::Metrics::Registry.new
      exporter = Punch::OTLP::TraceExporter.new(config(receiver), registry: registry, batch_spans: 2, delay: 50.milliseconds)
      tracer = Punch::Trace::Tracer.new(exporters: [exporter] of Punch::Trace::Exporter, events: [] of Punch::Trace::EventSink)
      tracer.start("first").finish
      tracer.start("second").finish # a batch of 2: 503, then sent again and taken
      Punch::Spec.eventually { exporter.counts.should eq({2, 0}) }
      receiver.answer(400)
      tracer.start("third").finish # sent after the delay: 400, dropped
      Punch::Spec.eventually { exporter.counts.should eq({2, 1}) }
      tracer.close
      receiver.snapshot.size.should eq(3)
      metrics = Punch::Spec.metrics(registry)
      metrics.value("punch.otlp.spans", "punch.otlp.outcome": "exported").should eq(2)
      metrics.value("punch.otlp.spans", "punch.otlp.outcome": "dropped").should eq(1)
    ensure
      receiver.close
    end
  end

  it "never makes a request wait: past its capacity, traces are dropped and counted" do
    exporter = Punch::OTLP::TraceExporter.new(Punch::OTLP::Config.new(traces: URI.parse("http://127.0.0.1:9/v1/traces"), timeout: 200.milliseconds),
      registry: Punch::Metrics::Registry.new, capacity: 1, batch_spans: 1_000_000, delay: 1.hour)
    tracer = Punch::Trace::Tracer.new(exporters: [exporter] of Punch::Trace::Exporter, events: [] of Punch::Trace::EventSink)
    elapsed = Time.measure { 200.times { tracer.start("request").finish } }
    elapsed.should be < 1.second
    exporter.counts[0].should eq(0)
    # Port 9 refuses; sending at close gives up within the timeout.
    tracer.close
    exporter.counts.sum.should eq(200)
  end
end

describe Punch::OTLP::Sender do
  it "stops retrying at shutdown: one last attempt, no pause" do
    receiver = Receiver.new
    begin
      5.times { receiver.answer(502) }
      sender = Punch::OTLP::Sender.new(URI.parse("#{receiver.url}/v1/traces"), Punch::OTLP::Headers.new, 1.second)
      result = Channel(Bool).new
      spawn { result.send(sender.post("{}", Time.instant + 1.minute)) }
      Punch::Spec.eventually { receiver.snapshot.size.should eq(1) } # 502 without Retry-After: pausing 1 s
      sender.hurry
      select
      when ok = result.receive
        ok.should be_false
      when timeout(500.milliseconds)
        fail "the pause did not end"
      end
      receiver.snapshot.size.should eq(2) # the pause ended, one more attempt, then given up
      sender.post("{}", Time.instant + 1.minute).should be_false
      receiver.snapshot.size.should eq(3) # once, no retry
    ensure
      receiver.close
    end
  end
end

describe Punch::OTLP::MetricExporter do
  it "sends gauges, counters, and histograms, and once more on stop" do
    receiver = Receiver.new
    begin
      registry = Punch::Metrics::Registry.new
      histogram = Punch::Metrics::Histogram.new([0.01, 0.1])
      histogram.record(0.005)
      histogram.record(0.05)
      registry.observe("punch.db.wal.frames", :gauge, "{frame}", "Frames") { |recorder| recorder.record(7, Punch::Metrics::Attributes{"db.namespace" => "primary"}) }
      registry.observe("app.sent", :counter, "{mail}", "Mails sent") { |recorder| recorder.record(3, Punch::Metrics::Attributes.new) }
      registry.observe("punch.db.checkpoint.duration", :histogram, "s", "Checkpoints") { |recorder| recorder.record(histogram.snapshot, Punch::Metrics::Attributes.new) }
      exporter = Punch::OTLP::MetricExporter.new(config(receiver), registry, interval: 1.hour)
      exporter.export.should be_true

      request = receiver.snapshot.first
      request.path.should eq("/v1/metrics")
      metrics = request.body["resourceMetrics"][0]["scopeMetrics"][0]["metrics"].as_a
      metrics.map(&.["name"].as_s).should eq(["app.sent", "punch.db.checkpoint.duration", "punch.db.wal.frames"])
      sum = metrics[0]["sum"]
      sum["aggregationTemporality"].should eq(2)
      sum["isMonotonic"].should be_true
      sum["dataPoints"][0]["asInt"].should eq("3")
      sum["dataPoints"][0]["startTimeUnixNano"].as_s.to_i128.should be > 0
      point = metrics[1]["histogram"]["dataPoints"][0]
      point["count"].should eq("2")
      point["bucketCounts"].should eq(["1", "1", "0"])
      point["explicitBounds"].should eq([0.01, 0.1])
      point["min"].should eq(0.005)
      gauge = metrics[2]["gauge"]["dataPoints"][0]
      gauge["asInt"].should eq("7")
      attribute(gauge["attributes"], "db.namespace").should eq({"stringValue" => "primary"})
      metrics[2]["unit"].should eq("{frame}")

      exporter.start
      exporter.stop
      receiver.snapshot.size.should eq(2)
    ensure
      receiver.close
    end
  end
end
