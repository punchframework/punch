require "../spec_helper"
require "http/client"
require "log"
require "log/spec"

private alias Config = Punch::HTTP::Config
private alias Response = Punch::HTTP::Response

# Runs a server on a free port for the block, then shuts it down.
private def with_server(config = Config.new, handler : Punch::HTTP::Handler = ->(_c : Punch::HTTP::Context) { Response.text(:ok, "hello") },
                        tracer = Punch::Trace::Tracer.new(events: [] of Punch::Trace::EventSink), &)
  server = Punch::HTTP::Server.new(config, tracer, &handler)
  port = server.bind(0).port
  done = Channel(Nil).new
  spawn do
    server.run(trap_signals: false)
    done.send(nil)
  end
  begin
    yield server, port
  ensure
    server.shutdown
    done.receive
  end
end

# Sends raw bytes and returns everything the server writes until it closes
# the connection or *timeout* passes.
private def raw(port : Int32, request : String, timeout = 2.seconds) : String
  socket = TCPSocket.new("127.0.0.1", port)
  socket.read_timeout = timeout
  socket << request
  socket.flush
  output = IO::Memory.new
  begin
    IO.copy(socket, output)
  rescue IO::TimeoutError
  end
  output.to_s
ensure
  socket.try(&.close)
end

private def get(port : Int32, path = "/", headers = HTTP::Headers.new) : HTTP::Client::Response
  HTTP::Client.new("127.0.0.1", port).get(path, headers)
end

lib LibC
  fun setrlimit(resource : Int, rlim : Rlimit*) : Int
end

# Sends a GET on *socket* and returns the status line, or `nil` when none
# comes within *timeout*.
private def status_line(socket : TCPSocket, timeout = 2.seconds) : String?
  socket.read_timeout = timeout
  socket << "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
  socket.flush
  socket.gets
rescue IO::TimeoutError
  nil
end

describe Punch::HTTP::Server do
  describe "responses" do
    it "sends the handler's response with Content-Length, in one piece" do
      with_server do |_server, port|
        output = raw(port, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        output.should start_with("HTTP/1.1 200 OK\r\n")
        output.should contain("Content-Length: 5\r\n")
        output.should_not contain("Transfer-Encoding")
        output.should end_with("\r\n\r\nhello")
      end
    end

    it "adds the security headers, a request ID, and Cache-Control" do
      with_server do |_server, port|
        response = get(port)
        response.headers["X-Content-Type-Options"].should eq("nosniff")
        response.headers["X-Frame-Options"].should eq("DENY")
        response.headers["Content-Security-Policy"].should contain("frame-ancestors 'none'")
        response.headers["Referrer-Policy"].should eq("strict-origin-when-cross-origin")
        response.headers["Cache-Control"].should eq("no-store")
        response.headers["Permissions-Policy"].should contain("camera=()")
        response.headers["X-Request-ID"].should match(/\A[0-9a-f]{32}\z/)
        response.headers.has_key?("Strict-Transport-Security").should be_false
      end
    end

    it "lets a handler set its own header, and the config change or drop defaults" do
      headers = Punch::HTTP::SecurityHeaders.new({"X-Frame-Options" => nil, "Referrer-Policy" => "no-referrer"})
      handler = ->(_c : Punch::HTTP::Context) { Response.new(:ok, "", HTTP::Headers{"Cache-Control" => "max-age=60"}) }
      with_server(Config.new(security_headers: headers), handler) do |_server, port|
        response = get(port)
        response.headers["Cache-Control"].should eq("max-age=60")
        response.headers["Referrer-Policy"].should eq("no-referrer")
        response.headers.has_key?("X-Frame-Options").should be_false
      end
    end

    it "answers HEAD without a body" do
      with_server do |_server, port|
        output = raw(port, "HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        output.should contain("Content-Length: 5\r\n")
        output.should end_with("\r\n\r\n")
      end
    end

    it "turns an exception into a 500 problem with the request ID, and logs it" do
      handler = ->(_c : Punch::HTTP::Context) : Response { raise "boom" }
      with_server(handler: handler) do |_server, port|
        Log.capture("punch.http") do |logs|
          response = get(port)
          response.status_code.should eq(500)
          response.headers["Content-Type"].should eq("application/problem+json")
          body = JSON.parse(response.body)
          body["status"].should eq(500)
          body["request_id"].should eq(response.headers["X-Request-ID"])
          body.to_json.should_not contain("boom")
          logs.check(:error, "unhandled exception")
        end
      end
    end

    it "emits one wide event per request, after the response, and none for /up" do
      events = Punch::Trace::MemoryEvents.new
      tracer = Punch::Trace::Tracer.new(events: [events] of Punch::Trace::EventSink)
      with_server(tracer: tracer) do |_server, port|
        response = get(port, "/invoices?page=2", HTTP::Headers{"User-Agent" => "spec"})
        get(port, "/up")
        Punch::Spec.eventually { events.events.size.should eq(1) }
        event = events.events.first
        event.name.should eq("GET")
        event.kind.server?.should be_true
        event["url.path"].should eq("/invoices")
        event["http.request.method"].should eq("GET")
        event["http.response.status_code"].should eq(200)
        event["http.response.body.size"].should eq(5)
        event["user_agent.original"].should eq("spec")
        event["client.address"].should eq("127.0.0.1")
        event["punch.request_id"].should eq(response.headers["X-Request-ID"])
        # Without a forwarded ID, the request ID is the trace ID.
        event.trace_id.to_s.should eq(response.headers["X-Request-ID"])
        event.duration.should_not be_nil
      end
    end

    it "marks a 500 as an error on the wide event, with the exception's type" do
      events = Punch::Trace::MemoryEvents.new
      tracer = Punch::Trace::Tracer.new(events: [events] of Punch::Trace::EventSink)
      handler = ->(_c : Punch::HTTP::Context) : Response { raise ArgumentError.new("boom") }
      with_server(handler: handler, tracer: tracer) do |_server, port|
        Log.capture("punch.http") { get(port).status_code.should eq(500) }
        Punch::Spec.eventually { events.events.size.should eq(1) }
        event = events.events.first
        event.status.error?.should be_true
        event["exception.type"].should eq("ArgumentError")
        Punch::Trace.event_fields(event)["error"].should eq("ArgumentError")
      end
    end

    it "logs the wide event under punch.request with LogEvents" do
      tracer = Punch::Trace::Tracer.new(events: [Punch::Trace::LogEvents.new] of Punch::Trace::EventSink)
      with_server(tracer: tracer) do |_server, port|
        Log.capture("punch.request") do |logs|
          get(port, "/invoices")
          Punch::Spec.eventually { logs.check(:info, "GET") }
          logs.entry.data[:event].as_h["url.path"].should eq("/invoices")
        end
      end
    end

    it "emits nothing with telemetry off" do
      with_server(tracer: Punch::Trace::Tracer.off) do |_server, port|
        Log.capture("punch.request") do |logs|
          get(port).headers["X-Request-ID"].should match(/\A[0-9a-f]{32}\z/)
          sleep 50.milliseconds
          logs.empty
        end
      end
    end

    it "continues a trusted proxy's traceparent, and ignores anyone else's" do
      events = Punch::Trace::MemoryEvents.new
      tracer = Punch::Trace::Tracer.new(events: [events] of Punch::Trace::EventSink)
      parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
      trusted = Config.new(trusted_proxies: Punch::HTTP::TrustedProxies.parse(["127.0.0.0/8"]))
      with_server(trusted, tracer: tracer) do |_server, port|
        get(port, "/", HTTP::Headers{"traceparent" => parent}).headers["X-Request-ID"].should eq("4bf92f3577b34da6a3ce929d0e0e4736")
        Punch::Spec.eventually { events.events.size.should eq(1) }
        events.events.first.parent_id.to_s.should eq("00f067aa0ba902b7")
      end
      with_server(tracer: tracer) do |_server, port|
        get(port, "/", HTTP::Headers{"traceparent" => parent}).headers["X-Request-ID"].should_not eq("4bf92f3577b34da6a3ce929d0e0e4736")
        Punch::Spec.eventually { events.events.size.should eq(2) }
        events.events.last.parent_id.should be_nil
      end
    end
  end

  describe "request bodies" do
    body_handler = ->(c : Punch::HTTP::Context) do
      case body = c.read_body
      in String                    then Response.text(:ok, "#{body.bytesize}")
      in Punch::HTTP::BodyTooLarge then Response.problem(:payload_too_large, c.request_id)
      end
    end
    config = Config.new(max_body_size: 100)

    it "reads bodies up to the limit" do
      with_server(config, body_handler) do |_server, port|
        HTTP::Client.new("127.0.0.1", port).post("/", body: "a" * 100).body.should eq("100")
      end
    end

    it "refuses a declared length above the limit before reading" do
      with_server(config, body_handler) do |_server, port|
        output = raw(port, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n")
        output.should start_with("HTTP/1.1 413 ")
      end
    end

    it "refuses a chunked body that grows past the limit" do
      with_server(config, body_handler) do |_server, port|
        chunk = "a" * 60
        output = raw(port, "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3c\r\n#{chunk}\r\n3c\r\n#{chunk}\r\n0\r\n\r\n")
        output.should start_with("HTTP/1.1 413 ")
      end
    end

    it "lets an operation raise its limit" do
      handler = ->(c : Punch::HTTP::Context) do
        body = c.read_body(limit: 1000)
        Response.text(:ok, body.is_a?(String) ? body.bytesize.to_s : "too large")
      end
      with_server(config, handler) do |_server, port|
        HTTP::Client.new("127.0.0.1", port).post("/", body: "a" * 500).body.should eq("500")
      end
    end

    it "refuses multipart requests before the handler runs" do
      called = Atomic(Bool).new(false)
      handler = ->(_c : Punch::HTTP::Context) { called.set(true); Response.text(:ok, "") }
      with_server(handler: handler) do |_server, port|
        headers = HTTP::Headers{"Content-Type" => "Multipart/Form-Data; boundary=x"}
        HTTP::Client.new("127.0.0.1", port).post("/", headers, body: "--x--").status_code.should eq(415)
        # A second Content-Type header does not hide it.
        raw(port, "POST / HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Type: multipart/form-data; boundary=x\r\nContent-Length: 5\r\n\r\n--x--").should start_with("HTTP/1.1 415 ")
        called.get.should be_false
      end
    end

    it "refuses a request with both Content-Length and Transfer-Encoding" do
      with_server do |_server, port|
        raw(port, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n").should start_with("HTTP/1.1 400 ")
      end
    end

    it "refuses oversized headers" do
      with_server(Config.new(max_headers_size: 1024)) do |_server, port|
        raw(port, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: #{"a" * 2000}\r\n\r\n").should start_with("HTTP/1.1 431 ")
      end
    end
  end

  describe "behind a proxy" do
    echo = ->(c : Punch::HTTP::Context) { Response.text(:ok, "#{c.client_ip} #{c.https?}") }
    trusted = Config.new(trusted_proxies: Punch::HTTP::TrustedProxies.parse(["127.0.0.0/8", "10.0.0.0/8"]))

    it "takes the client from X-Forwarded-For when the peer is a trusted proxy" do
      with_server(trusted, echo) do |_server, port|
        headers = HTTP::Headers{"X-Forwarded-For" => "6.6.6.6, 203.0.113.9, 10.1.1.1", "X-Forwarded-Proto" => "https"}
        response = get(port, "/", headers)
        response.body.should eq("203.0.113.9 true")
        response.headers["Strict-Transport-Security"].should eq("max-age=63072000")
      end
    end

    it "ignores a forwarded request ID that is not UTF-8" do
      with_server(trusted, echo) do |_server, port|
        output = raw(port, "GET / HTTP/1.1\r\nHost: x\r\nX-Request-ID: a#{String.new(Bytes[0xFF])}\r\nConnection: close\r\n\r\n")
        output.should start_with("HTTP/1.1 200")
      end
    end

    it "reads several X-Forwarded-For headers as one list" do
      with_server(trusted, echo) do |_server, port|
        output = raw(port, "GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 198.51.100.1\r\nX-Forwarded-For: 10.0.0.2\r\nConnection: close\r\n\r\n")
        output.should end_with("198.51.100.1 false")
      end
    end

    it "stops at an entry that does not parse" do
      with_server(trusted, echo) do |_server, port|
        get(port, "/", HTTP::Headers{"X-Forwarded-For" => "198.51.100.1, garbage, 10.0.0.2"}).body.should eq("10.0.0.2 false")
      end
    end

    it "takes a well-formed X-Request-ID from a trusted proxy only" do
      with_server(trusted, echo) do |_server, port|
        get(port, "/", HTTP::Headers{"X-Request-ID" => "edge-42"}).headers["X-Request-ID"].should eq("edge-42")
        # A malformed one is replaced by a fresh ID (random hex, which may
        # itself contain "bad", so compare the shape).
        get(port, "/", HTTP::Headers{"X-Request-ID" => "bad id <script>"}).headers["X-Request-ID"].should match(/\A[0-9a-f]{32}\z/)
        get(port, "/", HTTP::Headers{"X-Request-ID" => "a" * 129}).headers["X-Request-ID"].size.should eq(32)
      end
      with_server(handler: echo) do |_server, port|
        get(port, "/", HTTP::Headers{"X-Request-ID" => "edge-42"}).headers["X-Request-ID"].should_not eq("edge-42")
      end
    end

    it "warns once when forwarded headers come from an untrusted peer" do
      with_server(handler: echo) do |_server, port|
        Log.capture("punch.http") do |logs|
          2.times { get(port, "/", HTTP::Headers{"X-Forwarded-For" => "203.0.113.9"}) }
          logs.check(:warn, /not a trusted proxy/)
          expect_raises(Spec::AssertionFailed) { logs.check(:warn, /not a trusted proxy/) }
        end
      end
    end

    it "ignores forwarded headers from anyone else" do
      with_server(handler: echo) do |_server, port|
        headers = HTTP::Headers{"X-Forwarded-For" => "203.0.113.9", "X-Forwarded-Proto" => "https"}
        response = get(port, "/", headers)
        response.body.should eq("127.0.0.1 false")
        response.headers.has_key?("Strict-Transport-Security").should be_false
      end
    end
  end

  describe "health" do
    it "answers /up with 200 while every check passes, without calling the handler" do
      called = Atomic(Bool).new(false)
      handler = ->(_c : Punch::HTTP::Context) { called.set(true); Response.text(:ok, "") }
      with_server(handler: handler) do |server, port|
        healthy = Atomic(Bool).new(true)
        server.health_check("database") { healthy.get ? nil : "locked" }
        get(port, "/up").status_code.should eq(200)
        healthy.set(false)
        response = get(port, "/up")
        response.status_code.should eq(503)
        JSON.parse(response.body)["checks"]["database"].should eq("locked")
        called.get.should be_false
      end
    end

    it "names failing checks only to the machine and the trusted proxies" do
      config = Config.new(trusted_proxies: Punch::HTTP::TrustedProxies.parse(["127.0.0.1"]))
      with_server(config) do |server, port|
        server.health_check("database") { "locked" }
        outside = get(port, "/up", HTTP::Headers{"X-Forwarded-For" => "203.0.113.9"})
        outside.status_code.should eq(503)
        outside.body.should eq(%({"status":"failing"}))
        JSON.parse(get(port, "/up").body)["checks"]["database"].should eq("locked")
      end
    end

    it "reports a check that raises as failing" do
      with_server do |server, port|
        server.health_check("broken") { raise "no connection" }
        get(port, "/up").status_code.should eq(503)
      end
    end
  end

  describe "timeouts" do
    it "closes a connection that stays silent" do
      with_server(Config.new(read_timeout: 200.milliseconds)) do |_server, port|
        started = Time.instant
        raw(port, "GET / HTTP/1.1\r\nHost: x\r\n", timeout: 5.seconds).should eq("")
        (Time.instant - started).should be < 2.seconds
      end
    end

    it "answers 408 when a body stops arriving" do
      handler = ->(c : Punch::HTTP::Context) { c.read_body; Response.text(:ok, "") }
      with_server(Config.new(read_timeout: 200.milliseconds), handler) do |_server, port|
        raw(port, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc", timeout: 5.seconds).should start_with("HTTP/1.1 408 ")
      end
    end
  end

  describe "connections" do
    it "waits at max_connections for a connection to close, then accepts" do
      with_server(Config.new(max_connections: 2)) do |_server, port|
        held = Array.new(2) { TCPSocket.new("127.0.0.1", port) }
        held.each { |socket| status_line(socket).should eq("HTTP/1.1 200 OK") }
        waiting = TCPSocket.new("127.0.0.1", port)
        status_line(waiting, 300.milliseconds).should be_nil
        held.pop.close
        waiting.gets.should eq("HTTP/1.1 200 OK")
        waiting.close
        held.each(&.close)
      end
    end

    it "keeps accepting after accept fails for want of file descriptors" do
      limit = LibC::Rlimit.new
      LibC.getrlimit(LibC::RLIMIT_NOFILE, pointerof(limit)).should eq(0)
      with_server do |_server, port|
        Log.capture("punch.http") do |logs|
          # The client takes the lowest free descriptor and leaves the
          # server's accept none below the lowered limit.
          lowest = File.open(__FILE__, &.fd)
          lowered = LibC::Rlimit.new(rlim_cur: lowest.to_u64 + 1, rlim_max: limit.rlim_max)
          client = begin
            LibC.setrlimit(LibC::RLIMIT_NOFILE, pointerof(lowered)).should eq(0)
            socket = TCPSocket.new("127.0.0.1", port)
            sleep 100.milliseconds
            socket
          ensure
            LibC.setrlimit(LibC::RLIMIT_NOFILE, pointerof(limit))
          end
          logs.check(:warn, /accept failed/)
          status_line(client).should eq("HTTP/1.1 200 OK")
          client.close
          get(port).status_code.should eq(200)
        end
      end
    end

    it "takes its default from the open-file limit, less a reserve" do
      limit = LibC::Rlimit.new
      LibC.getrlimit(LibC::RLIMIT_NOFILE, pointerof(limit))
      expected = (limit.rlim_cur.to_u64 - Config::FD_RESERVE).clamp(16_u64, 65_536_u64)
      Config.new.max_connections.should eq(expected)
    end
  end

  describe "shutdown" do
    it "finishes requests in progress, then refuses new connections" do
      started = Channel(Nil).new
      handler = ->(_c : Punch::HTTP::Context) { started.send(nil); sleep 300.milliseconds; Response.text(:ok, "done") }
      server = Punch::HTTP::Server.new(Config.new, Punch::Trace::Tracer.off, &handler)
      port = server.bind(0).port
      spawn { server.run(trap_signals: false) }
      result = Channel(HTTP::Client::Response).new
      spawn { result.send(get(port)) }
      started.receive
      stopped = Channel(Nil).new
      spawn { server.shutdown; stopped.send(nil) }
      sleep 50.milliseconds
      server.draining?.should be_true
      expect_raises(Socket::ConnectError) { TCPSocket.new("127.0.0.1", port) }
      response = result.receive
      response.body.should eq("done")
      response.headers["Connection"].should eq("close")
      stopped.receive
    end

    it "closes idle keep-alive connections at once" do
      with_server do |server, port|
        client = HTTP::Client.new("127.0.0.1", port)
        client.get("/").status_code.should eq(200)
        started = Time.instant
        server.shutdown
        (Time.instant - started).should be < 1.second
        client.close
      end
    end

    it "cuts requests that outlast the shutdown timeout, then runs the hooks in order" do
      started = Channel(Nil).new
      handler = ->(_c : Punch::HTTP::Context) { started.send(nil); sleep 10.seconds; Response.text(:ok, "") }
      server = Punch::HTTP::Server.new(Config.new(shutdown_timeout: 200.milliseconds), Punch::Trace::Tracer.off, &handler)
      port = server.bind(0).port
      steps = [] of String
      server.on_shutdown("jobs") { steps << "jobs" }
      server.on_shutdown("broken") { raise "fails" }
      server.on_shutdown("checkpoint") { steps << "checkpoint" }
      spawn { server.run(trap_signals: false) }
      spawn { get(port) rescue nil }
      started.receive
      begun = Time.instant
      server.shutdown
      (Time.instant - begun).should be < 2.seconds
      steps.should eq(["jobs", "checkpoint"])
    end

    it "keeps serving during the drain delay, with /up at 503" do
      server = Punch::HTTP::Server.new(Config.new(drain_delay: 500.milliseconds), Punch::Trace::Tracer.off) { Response.text(:ok, "served") }
      port = server.bind(0).port
      spawn { server.run(trap_signals: false) }
      get(port, "/up").status_code.should eq(200)
      stopped = Channel(Nil).new
      spawn { server.shutdown; stopped.send(nil) }
      sleep 100.milliseconds
      get(port, "/up").status_code.should eq(503)
      response = get(port)
      response.body.should eq("served")
      response.headers["Connection"].should eq("close")
      stopped.receive
      expect_raises(Socket::ConnectError) { TCPSocket.new("127.0.0.1", port) }
    end
  end

  it "serves many clients on several threads" do
    handler = ->(c : Punch::HTTP::Context) { Response.text(:ok, c.request.path) }
    with_server(handler: handler) do |_server, port|
      results = Channel(Bool).new
      16.times do |client_number|
        spawn do
          client = HTTP::Client.new("127.0.0.1", port)
          ok = (1..50).all? do |request_number|
            path = "/#{client_number}/#{request_number}"
            response = client.get(path)
            response.status_code == 200 && response.body == path
          end
          client.close
          results.send(ok)
        end
      end
      16.times { results.receive.should be_true }
    end
  end
end
