require "../spec_helper"
require "log/spec"

private alias Trace = Punch::Trace

private def recording_tracer(**options) : {Trace::Tracer, Trace::MemoryExporter, Trace::MemoryEvents}
  exporter = Trace::MemoryExporter.new
  events = Trace::MemoryEvents.new
  tracer = Trace::Tracer.new(**options, exporters: [exporter] of Trace::Exporter, events: [events] of Trace::EventSink)
  {tracer, exporter, events}
end

describe Punch::Trace do
  describe Trace::SpanContext do
    it "reads and writes traceparent" do
      header = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      context = Trace::SpanContext.parse?(header).should_not be_nil
      context.trace_id.to_s.should eq("4bf92f3577b34da6a3ce929d0e0e4736")
      context.span_id.to_s.should eq("00f067aa0ba902b7")
      context.sampled?.should be_true
      context.traceparent.should eq(header)
      unsampled = Trace::SpanContext.parse?(header.sub(/01\z/, "00")).should_not be_nil
      unsampled.sampled?.should be_false
    end

    it "reads a later version by its first four fields" do
      Trace::SpanContext.parse?("cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-what-comes-next").should_not be_nil
      Trace::SpanContext.parse?("cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x").should be_nil
    end

    it "refuses malformed headers" do
      [
        "",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra", # version 00 has exactly four fields
        "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",       # version ff is invalid
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",       # uppercase
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01",       # zero trace ID
        "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",       # zero span ID
        "00-4bf92f3577b34da6a3ce929d0e0e473-600f067aa0ba902b7-01",       # misplaced dash
        "00_4bf92f3577b34da6a3ce929d0e0e4736_00f067aa0ba902b7_01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0g",
      ].each { |header| Trace::SpanContext.parse?(header).should be_nil }
    end
  end

  describe Trace::Tracer do
    it "records a tree of spans with distinct IDs in one trace" do
      tracer, exporter, events = recording_tracer
      root = tracer.start("GET /invoices")
      child = root.child("work")
      grandchild = child.child("step", :client)
      grandchild.finish
      child.finish
      root.finish

      trace = exporter.traces.first
      trace.root.should be(root)
      trace.spans.should eq([grandchild, child])
      ids = [root, child, grandchild].map(&.span_id.to_s)
      ids.uniq.size.should eq(3)
      ids.each(&.should(match(/\A[0-9a-f]{16}\z/)))
      child.parent_id.should eq(root.span_id)
      grandchild.parent_id.should eq(child.span_id)
      grandchild.trace_id.should eq(root.trace_id)
      grandchild.root.should be(root)
      events.events.should eq([root])
      (grandchild.start_time >= root.start_time).should be_true
    end

    it "continues a remote parent" do
      tracer, _, _ = recording_tracer
      parent = Trace::SpanContext.parse?("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00").should_not be_nil
      root = tracer.start("GET", parent: parent)
      root.trace_id.to_s.should eq("4bf92f3577b34da6a3ce929d0e0e4736")
      root.parent_id.to_s.should eq("00f067aa0ba902b7")
      # The parent did not sample, so neither does this trace.
      root.sampled?.should be_false
      root.child("x").should be(Trace::Span::NOOP)
    end

    it "samples by trace ID, and always emits the wide event" do
      tracer, exporter, events = recording_tracer(sample_ratio: 0.5)
      roots = Array.new(400) { tracer.start("GET").tap(&.finish) }
      events.events.size.should eq(400)
      sampled = exporter.traces.size
      sampled.should be_close(200, 60)
      roots.count(&.sampled?).should eq(sampled)
      roots.each { |root| root.sampled?.should eq(root.trace_id.try(&.low).should_not(be_nil) < 2_u64**63) }
    end

    it "records only the root when nothing exports" do
      events = Trace::MemoryEvents.new
      tracer = Trace::Tracer.new(events: [events] of Trace::EventSink)
      root = tracer.start("GET")
      root.child("x").should be(Trace::Span::NOOP)
      root.add("punch.db.queries", 1)
      root.finish
      events.events.first["punch.db.queries"].should eq(1)
    end

    it "is all NOOP when off" do
      root = Trace::Tracer.off.start("GET")
      root.should be(Trace::Span::NOOP)
      root.recording?.should be_false
      root.set("a", "b")
      root["a"]?.should be_nil
      root.child("x").should be(Trace::Span::NOOP)
      root.trace_id.should be_nil
      root.finish
    end

    it "caps the spans per trace and counts the rest" do
      tracer, exporter, _ = recording_tracer
      root = tracer.start("GET")
      (Trace::Recording::MAX_SPANS + 10).times { root.child("query").finish }
      root.finish
      trace = exporter.traces.first
      (trace.spans.size + 1).should eq(Trace::Recording::MAX_SPANS)
      root["punch.trace.dropped_spans"].should eq(11)
    end

    it "keeps going when an exporter fails" do
      failing = FailingExporter.new
      exporter = Trace::MemoryExporter.new
      tracer = Trace::Tracer.new(exporters: [failing, exporter] of Trace::Exporter, events: [] of Trace::EventSink)
      Log.capture("punch.trace") do |logs|
        tracer.start("GET").finish
        logs.check(:error, /exporter FailingExporter failed/)
      end
      exporter.traces.size.should eq(1)
    end
  end

  describe Trace::Span do
    it "adds totals and keeps types" do
      tracer, _, _ = recording_tracer
      root = tracer.start("GET")
      root.add("count", 2)
      root.add("count", 3)
      root.add("ms", 0.5)
      root.add("ms", 1_i64)
      root["count"].should eq(5)
      root["ms"].should eq(1.5)
      root.set("small", 7_u8)
      root["small"].should eq(7)
    end

    it "records an exception in #span, finishes the span, and raises again" do
      trace = Punch::Spec.trace do
        expect_raises(ArgumentError, "bad") do
          Trace.span("charge card", :client) { raise ArgumentError.new("bad") }
        end
      end
      span = trace["charge card"]
      span.finished?.should be_true
      span.kind.client?.should be_true
      span.status.error?.should be_true
      span["exception.type"].should eq("ArgumentError")
      span["exception.message"].should eq("bad")
    end

    it "never prints its attributes" do
      trace = Punch::Spec.trace(&.set("customer.email", "ann@example.org"))
      trace.root.inspect.should_not contain("ann@")
    end
  end

  describe "the current span" do
    it "is scoped to a fiber, and restored after the block" do
      Trace.current.should be(Trace::Span::NOOP)
      Punch::Spec.trace do |root|
        Trace.current.should be(root)
        Trace.event.should be(root)
        seen = Channel(Trace::Span).new(1)
        spawn { seen.send(Trace.current) }
        seen.receive.should be(Trace::Span::NOOP)
        Trace.span("inner") do |inner|
          Trace.current.should be(inner)
          Trace.event.should be(root)
        end
        Trace.current.should be(root)
      end
      Trace.current.should be(Trace::Span::NOOP)
    end

    it "keeps the wide event reachable below children that do not record" do
      events = Trace::MemoryEvents.new
      tracer = Trace::Tracer.new(events: [events] of Trace::EventSink)
      root = tracer.start("unsampled")
      Trace.with(root) do
        Trace.span("read") do |child|
          child.should be(Trace::Span::NOOP)
          Trace.event.should be(root)
          Trace.event["invoice.id"] = "7"
        end
      end
      Trace.event.should be(Trace::Span::NOOP)
      root.finish
      events.events.first["invoice.id"].should eq("7")
    end

    it "records each exception of a trace once, with the last span that recorded it" do
      trace = Punch::Spec.trace do |root|
        error = ArgumentError.new("bad")
        Trace.span("subscriber") do |span|
          span.error(error)
          root.record_exception(error)
        end
        root.error(error)
        root.record_exception(KeyError.new("other"), "elsewhere")
      end
      trace.root.exceptions.map { |raised| {raised.source, raised.exception.class.name} }.should eq([{"spec", "ArgumentError"}, {"elsewhere", "KeyError"}])
      trace.root.status.error?.should be_true
    end

    it "keeps list attributes up to a limit" do
      trace = Punch::Spec.trace do |root|
        3.times { |index| root.append("punch.events", "E#{index}", limit: 2) }
      end
      trace.root["punch.events"].should eq(["E0", "E1"])
    end

    it "keeps parallel traces apart on several threads" do
      tracer, exporter, _ = recording_tracer
      done = Channel(Nil).new
      32.times do |index|
        spawn do
          root = tracer.start("trace #{index}")
          Trace.with(root) do
            50.times do |step|
              Trace.span("step #{step}") do |span|
                Fiber.yield
                Trace.event.add("steps", 1)
                span["index"] = index
              end
            end
          end
          root.finish
          done.send(nil)
        end
      end
      32.times { done.receive }
      exporter.traces.size.should eq(32)
      exporter.traces.each do |trace|
        index = trace.root.name.split(' ').last.to_i64
        trace.root["steps"].should eq(50)
        trace.spans.size.should eq(50)
        trace.spans.each do |span|
          span["index"].should eq(index)
          span.trace_id.should eq(trace.root.trace_id)
          span.parent_id.should eq(trace.root.span_id)
        end
      end
    end
  end

  describe "exporters and sinks" do
    it "prints a trace as an indented tree" do
      io = IO::Memory.new
      tracer = Trace::Tracer.new(exporters: [Trace::ConsoleExporter.new(io, color: false)] of Trace::Exporter, events: [] of Trace::EventSink)
      root = tracer.start("GET /invoices/:invoice_id")
      root["http.response.status_code"] = 200
      root["punch.outcome"] = "shown"
      Trace.with(root) do
        Trace.span("primary read") do
          Trace.span("Billing::Queries.invoice_by_id", :client, &.set("db.response.returned_rows", 1))
        end
      end
      root.finish
      lines = io.to_s.lines
      lines[0].should match(/\AGET \/invoices\/:invoice_id 200 shown  \d+\.\d\d ms  trace [0-9a-f]{32}\z/)
      lines[1].should match(/\A +\+\d+\.\d\d +\d+\.\d\d ms  primary read\z/)
      lines[2].should match(/\A +\+\d+\.\d\d +\d+\.\d\d ms    Billing::Queries.invoice_by_id rows=1\z/)
    end

    it "writes wide events as JSON lines" do
      io = IO::Memory.new
      tracer = Trace::Tracer.new(events: [Trace::JSONEvents.new(io)] of Trace::EventSink)
      root = tracer.start("GET /invoices")
      root["http.response.status_code"] = 200
      root["tags"] = ["a", "b"]
      root.finish
      tracer.close
      event = JSON.parse(io.to_s.lines.first)
      event["time"].as_s.should match(/\A\d{4}-\d\d-\d\dT/)
      event["name"].should eq("GET /invoices")
      event["trace_id"].as_s.should eq(root.trace_id.to_s)
      event["http.response.status_code"].should eq(200)
      event["tags"].should eq(["a", "b"])
      event["duration_ms"].as_f.should be >= 0.0
    end

    it "escapes what JSON requires, and keeps any text valid" do
      tracer = Trace::Tracer.new(events: [] of Trace::EventSink)
      root = tracer.start(%(GET "quoted"\\path))
      texts = ["tab\there", "line\nbreak", %(quote " and \\ backslash), "Grüße 日本 🎉", "\u{7f}\u{1}", String.new(Bytes[0x66, 0xff, 0x6f])]
      texts.each_with_index { |text, index| root["text.#{index}"] = text }
      root["user_agent.original"] = "</script>"
      root["nan"] = Float64::NAN
      root.finish
      io = IO::Memory.new
      Trace::JSONEvents.write(io, root)
      line = io.to_s
      line.should_not contain('\n')
      json = JSON.parse(line)
      json["name"].should eq(%(GET "quoted"\\path))
      texts[0, 5].each_with_index { |text, index| json["text.#{index}"].should eq(text) }
      json["text.5"].as_s.should start_with("f")
      json["nan"].raw.should be_nil
      json["user_agent.original"].should eq("</script>")
    end

    it "writes every JSON line from parallel requests before close returns" do
      io = IO::Memory.new
      sink = Trace::JSONEvents.new(io, capacity: 8)
      tracer = Trace::Tracer.new(events: [sink] of Trace::EventSink)
      done = Channel(Nil).new
      16.times do
        spawn do
          100.times { tracer.start("GET").finish }
          done.send(nil)
        end
      end
      16.times { done.receive }
      tracer.close
      lines = io.to_s.lines
      lines.size.should eq(1600)
      lines.map { |line| JSON.parse(line)["trace_id"].as_s }.uniq!.size.should eq(1600)
    end

    it "prints without color when not on a terminal" do
      io = IO::Memory.new
      tracer = Trace::Tracer.new(exporters: [Trace::ConsoleExporter.new(io)] of Trace::Exporter, events: [] of Trace::EventSink)
      tracer.start("GET").finish
      io.to_s.should start_with("GET  ")
      io.to_s.should_not contain("\e[")
    end
  end

  describe "database spans" do
    it "records each statement with its name, text, and rows, never its arguments" do
      Punch::Spec.database do |db|
        db.write(&.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT"))
        trace = Punch::Spec.trace do
          db.write do |writer|
            writer.exec("INSERT INTO notes (body) VALUES (?)", "secret body", name: "Notes.insert")
            writer.exec("INSERT INTO notes (body) VALUES (?)", "another")
          end
          db.read do |reader|
            reader.query_all("SELECT body FROM notes", name: "Notes.all", &.read(String))
            reader.query_one?("SELECT body FROM notes WHERE id = ?", 1_i64, &.read(String))
            reader.query_each("  select id from notes") { }
          end
        end

        trace.should have_span("memory write", "db.namespace": "memory")
        trace.should have_span("Notes.insert", "db.system.name": "sqlite", "db.operation.name": "INSERT",
          "punch.db.changes": 1, "punch.query": "Notes.insert")
        trace.should have_span("INSERT", "punch.db.changes": 1)
        trace.should have_span("Notes.all", "db.response.returned_rows": 2, "db.query.text": "SELECT body FROM notes")
        trace.should have_span("SELECT", "db.response.returned_rows": 1)
        trace.should have_span("SELECT", "db.response.returned_rows": 2, "db.query.text": "  select id from notes")
        trace["Notes.all"].parent_id.should eq(trace["memory read"].span_id)
        trace["Notes.all"].kind.client?.should be_true

        root = trace.root
        root["punch.db.queries"].should eq(5)
        root["punch.db.rows"].should eq(5)
        root["punch.db.changes"].should eq(2)
        root["punch.db.duration_ms"].as(Float64).should be > 0.0
        root["punch.db.writer_wait_ms"].as(Float64).should be >= 0.0
        trace.each_span { |span| span.attributes.values.should_not contain("secret body") }
      end
    end

    it "marks a failing statement and the transaction" do
      Punch::Spec.database do |db|
        trace = Punch::Spec.trace do
          expect_raises(Punch::Database::Error) do
            db.read(&.query_all("SELECT * FROM missing", &.read(Int64)))
          end
        end
        trace["memory read"].status.error?.should be_true
        trace.root["punch.db.errors"].should eq(1)
        trace["SELECT"].status.error?.should be_true
      end
    end

    it "makes the transaction span current inside a write, on the writer's thread" do
      Punch::Spec.database do |db|
        trace = Punch::Spec.trace do
          db.write { |_writer| Trace.span("inside") { } }
        end
        trace["inside"].parent_id.should eq(trace["memory write"].span_id)
      end
    end

    it "costs nothing but the totals without a trace" do
      Punch::Spec.database do |db|
        db.read(&.query_all("SELECT 1", &.read(Int64))).should eq([1])
      end
    end
  end
end

class FailingExporter < Punch::Trace::Exporter
  def export(trace : Punch::Trace::Finished) : Nil
    raise "exporter down"
  end
end
