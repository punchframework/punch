require "http/server"
require "json"
require "log"

module Punch::HTTP
  # What the server calls for every request except the health check: the
  # router.
  alias Handler = Context -> Response

  # The HTTP kernel: stdlib parsing, Punch's own connection handling.
  # HTTP/1.1 only; TLS and HTTP/2 belong to the reverse proxy.
  #
  # ```
  # server = Punch::HTTP::Server.new(config) { |context| Punch::HTTP::Response.text(:ok, "hi") }
  # server.run # blocks; SIGINT or SIGTERM drains and returns
  # ```
  #
  # Every response leaves in one piece with `Content-Length`, carries the
  # security headers and `X-Request-ID`, and is traced: the request's root
  # span is its wide event (`docs/tracing.md`). Multipart
  # requests are refused with 415 before the handler runs. `GET /up` answers
  # 200 while every health check passes and 503 once shutdown has begun.
  class Server
    Log = ::Log.for("punch.http")

    HEALTH_PATH = "/up"

    # The first pause after a failed `accept`; it doubles up to a second.
    ACCEPT_PAUSE = 10.milliseconds

    # A health check returns `nil` when healthy, or the reason it is not.
    alias HealthCheck = -> String?
    alias ShutdownHook = -> Nil

    # One accepted connection. `busy` is true from the moment a request
    # reaches the kernel until its response has been written.
    private class Connection
      getter io : IO
      getter processor : ::HTTP::Server::RequestProcessor
      getter busy = Atomic(Bool).new(false)

      def initialize(@io : IO, @processor : ::HTTP::Server::RequestProcessor)
      end
    end

    getter config : Config

    @listeners = [] of TCPServer
    @connections = Set(Connection).new
    @lock = Mutex.new
    @draining = Atomic(Bool).new(false)
    @warned_forwarded = Atomic(Bool).new(false)
    @closed = Channel(Nil).new
    @health_checks = [] of {String, HealthCheck}
    @shutdown_hooks = [] of {String, ShutdownHook}
    @drain_hooks = [] of {String, ShutdownHook}
    # One entry per open connection, at most `max_connections`: the
    # accept loop waits for a free one instead of running out of file
    # descriptors.
    @slots : Channel(Nil)

    getter tracer : Trace::Tracer
    # Answers probes and banned addresses before a request is traced
    # (`docs/http.md`, "Probes and bans"), with the patterns of
    # `Probes.patterns` when the server was made.
    getter guard : Probes::Guard

    def initialize(@config : Config, @tracer : Trace::Tracer = Trace::Tracer.new, &@handler : Handler)
      @slots = Channel(Nil).new(config.max_connections)
      @guard = Probes::Guard.new(config.probes, Probes.patterns, config.trusted_proxies)
    end

    # Binds the configured address, or *port* when given (0: any free port,
    # for specs). Returns the bound address.
    def bind(port : Int32 = config.port) : Socket::IPAddress
      listener = TCPServer.new(config.host, port)
      @lock.synchronize { @listeners << listener }
      listener.local_address
    end

    # Registers a health check for `/up`, such as a database ping.
    def health_check(name : String, &check : HealthCheck) : Nil
      @health_checks << {name, check}
    end

    # Registers a step that runs after requests have drained, in order:
    # jobs, then the WAL checkpoint.
    def on_shutdown(name : String, &hook : ShutdownHook) : Nil
      @shutdown_hooks << {name, hook}
    end

    # Registers a step that runs once no new connections are accepted,
    # before waiting for requests in progress: ending live streams, which
    # would otherwise hold the drain until `shutdown_timeout`.
    def on_drain(name : String, &hook : ShutdownHook) : Nil
      @drain_hooks << {name, hook}
    end

    def draining? : Bool
      @draining.get
    end

    # Accepts connections until `shutdown` has finished. With *trap_signals*,
    # SIGINT and SIGTERM start the shutdown.
    def run(trap_signals : Bool = true) : Nil
      bind if @listeners.empty?
      if trap_signals
        # SIGINT arrives as `interrupted`, SIGTERM as `session_ended`. SIGHUP
        # is ignored. A second signal during the drain exits at once.
        Process.on_terminate do |reason|
          next unless reason.interrupted? || reason.session_ended?
          if draining?
            Log.warn { "second signal: exiting without waiting for the drain" }
            Process.exit(1)
          end
          spawn shutdown
        end
      end
      @listeners.each { |listener| spawn accept_loop(listener) }
      Log.info { "listening on #{@listeners.map(&.local_address).join(", ")}" }
      @closed.receive?
    end

    # Graceful shutdown: `/up` turns 503 and responses carry
    # `Connection: close`; after `drain_delay` no new connections are
    # accepted, idle connections close, requests in progress finish, and
    # after `shutdown_timeout` the rest are cut. Then the shutdown hooks
    # run, and last the tracer closes, writing out buffered events. Safe to
    # call more than once.
    def shutdown : Nil
      return if @draining.swap(true)

      Log.info { "shutting down" }
      sleep config.drain_delay if config.drain_delay.positive?
      listeners = @lock.synchronize { @listeners.dup.tap { @listeners.clear } }
      listeners.each { |listener| listener.close rescue nil }
      @drain_hooks.each do |name, hook|
        hook.call
      rescue ex
        Log.error(exception: ex) { "drain step #{name} failed" }
      end
      close_idle_connections

      deadline = Time.instant + config.shutdown_timeout
      until @lock.synchronize { @connections.empty? } || Time.instant >= deadline
        sleep 10.milliseconds
        close_idle_connections
      end
      remaining = @lock.synchronize { @connections.dup }
      unless remaining.empty?
        Log.warn { "shutdown timeout: closing #{remaining.size} connection(s) with requests in progress" }
        remaining.each { |connection| connection.io.close rescue nil }
      end

      @shutdown_hooks.each do |name, hook|
        hook.call
      rescue ex
        Log.error(exception: ex) { "shutdown step #{name} failed" }
      end
      @tracer.close
      Log.info { "stopped" }
      @closed.close
    end

    private def close_idle_connections : Nil
      @lock.synchronize do
        @connections.each do |connection|
          connection.processor.close
          connection.io.close rescue nil unless connection.busy.get
        end
      end
    end

    # Accepts until the listener closes. A failed `accept`, such as
    # EMFILE or a connection the client aborted, is logged and retried
    # after a pause that grows to a second; past `max_connections` the
    # loop waits for a connection to close. A loop that ends any other
    # way exits the process, so the supervisor starts a new one instead
    # of keeping a process that answers nothing.
    private def accept_loop(listener : TCPServer) : Nil
      pause = ACCEPT_PAUSE
      loop do
        @slots.send(nil)
        begin
          socket = listener.accept?
        rescue ex : IO::Error
          @slots.receive
          break if listener.closed?
          Log.warn(exception: ex) { "accept failed, retrying in #{pause.total_milliseconds.to_i} ms" }
          sleep pause
          pause = {pause * 2, 1.second}.min
          next
        end
        unless socket
          @slots.receive
          break
        end
        begin
          spawn serve(socket)
          pause = ACCEPT_PAUSE
        rescue ex
          # No memory for the fiber's stack.
          socket.close rescue nil
          @slots.receive
          Log.error(exception: ex) { "could not start a connection, retrying in #{pause.total_milliseconds.to_i} ms" }
          sleep pause
          pause = {pause * 2, 1.second}.min
        end
      end
    rescue ex
      Log.fatal(exception: ex) { "accept loop ended; exiting" }
      Process.exit(1)
    end

    private def serve(socket : TCPSocket) : Nil
      serve_connection(socket)
    ensure
      socket.close rescue nil
      @slots.receive
    end

    private def serve_connection(socket : TCPSocket) : Nil
      socket.sync = false
      socket.tcp_nodelay = true
      socket.read_timeout = config.read_timeout
      socket.write_timeout = config.write_timeout
      address = (socket.remote_address.address rescue "unknown")
      peer = TrustedProxies.canonical(address) || address

      connection = uninitialized Connection
      processor = ::HTTP::Server::RequestProcessor.new do |http|
        connection.busy.set(true)
        begin
          handle(http, peer)
        ensure
          connection.busy.set(false)
        end
      end
      processor.max_request_line_size = config.max_request_line_size
      processor.max_headers_size = config.max_headers_size
      connection = Connection.new(socket, processor)

      @lock.synchronize { @connections << connection }
      begin
        processor.process(socket)
      rescue IO::Error
        # The client went away.
      rescue ex
        # The standard library's parser gave up on malformed framing.
        Log.warn(exception: ex) { "connection from #{peer} failed" }
      ensure
        socket.close rescue nil
        @lock.synchronize { @connections.delete(connection) }
      end
    end

    # Runs one request in process, as a connection from *peer* would, and
    # returns the response as the client receives it: security headers and
    # `X-Request-ID` added, the trace finished. Nothing is bound or written;
    # `Punch::Spec::Client` uses this, so endpoint specs go through the same
    # code as real requests. A HEAD response keeps its body here; the
    # connection would not send it.
    def process(request : ::HTTP::Request, peer : String = "127.0.0.1") : Response
      if early = @guard.check(request, peer)
        return early
      end
      context, response = run(request, peer)
      finish(context.span, response)
      response
    end

    # Runs one request and writes its response completely before returning,
    # so that a connection is never closed between handler and write. The
    # trace ends after the write; `/up` is not traced.
    private def handle(http : ::HTTP::Server::Context, peer : String) : Nil
      {% if flag?(:punch_dev) %}
        return dev_reload(http) if http.request.path == Dev::PATH && http.request.method == "GET"
      {% end %}
      if early = @guard.check(http.request, peer)
        # A probe or a banned address: untraced.
        begin
          write(http, early)
        rescue IO::Error
          # The scanner went away.
        end
        return
      end
      context, response = run(http.request, peer)
      # A live page's stream stays open: its request ends, as a wide
      # event, once the stream has started.
      finish(context.span, response) if response.live
      begin
        write(http, response)
      rescue IO::Error
        # The client went away, or shutdown cut the connection.
        context.span.set("punch.response.interrupted", true)
      end
      finish(context.span, response) unless response.live
    end

    # A `punch dev` build's reload stream (`Punch::Dev`), untraced like
    # `/up`; it ends when the server drains.
    private def dev_reload(http : ::HTTP::Server::Context) : Nil
      output = http.response
      output.headers["Content-Type"] = "text/event-stream; charset=utf-8"
      output.headers["Cache-Control"] = "no-store"
      Dev.stream(output, -> { draining? })
      output.close
    rescue IO::Error
      # The client went away.
    end

    private def run(request : ::HTTP::Request, peer : String) : {Context, Response}
      tracer = request.path == HEALTH_PATH ? nil : @tracer
      context = Context.new(request, peer, config, tracer: tracer)
      span = context.span
      start(span, context)
      response = Trace.with(span) do
        respond(context)
      rescue IO::TimeoutError
        timeout = Response.problem(:request_timeout, context)
        timeout.headers["Connection"] = "close"
        timeout
      rescue Punch::Database::WriterBusy
        context.span.set("punch.outcome", "database_busy")
        busy = Response.problem(:service_unavailable, context, "database_busy")
        busy.headers["Retry-After"] = "1"
        busy
      rescue ex
        span.error(ex)
        Log.error(exception: ex, &.emit("unhandled exception", request_id: context.request_id))
        problem = Response.problem(:internal_server_error, context)
        Response.new(problem.status, problem.body, problem.headers, exception: ex)
      end
      {context, complete(context, response)}
    end

    # The handler's headers, then the security headers it did not set, HSTS
    # over HTTPS, the request ID, and `Connection: close` while draining.
    private def complete(context : Context, response : Response) : Response
      headers = response.headers.dup
      security = config.security_headers
      security.headers.each do |name, value|
        headers[name] = value unless headers.has_key?(name)
      end
      if security.default_csp? && !headers.has_key?("Content-Security-Policy")
        headers["Content-Security-Policy"] = SecurityHeaders.content_security_policy
      end
      if context.https? && (hsts = config.security_headers.hsts)
        headers["Strict-Transport-Security"] = hsts unless headers.has_key?("Strict-Transport-Security")
      end
      headers["X-Request-ID"] = context.request_id
      headers["Connection"] = "close" if draining?
      localize(context, headers) if context.localized?
      Response.new(response.status, response.body, headers, response.live, response.exception)
    end

    # A response rendered in a locale says which (`Content-Language`), and
    # one whose locale came from `Accept-Language` varies by it.
    private def localize(context : Context, headers : ::HTTP::Headers) : Nil
      locale = context.locale
      headers["Content-Language"] = locale.code unless headers.has_key?("Content-Language")
      context.span.set("punch.locale", locale.code) if context.span.recording?
      return unless context.negotiated?

      vary = headers["Vary"]?
      headers["Vary"] = vary ? "#{vary}, Accept-Language" : "Accept-Language" unless vary.try(&.includes?("Accept-Language"))
    end

    # The request's fields on its root span, by OpenTelemetry's HTTP
    # conventions.
    private def start(span : Trace::Span, context : Context) : Nil
      return unless span.recording?

      request = context.request
      span.set("http.request.method", request.method)
      span.set("url.path", request.path)
      span.set("url.scheme", context.https? ? "https" : "http")
      span.set("client.address", context.client_ip)
      request.headers["User-Agent"]?.try { |agent| span.set("user_agent.original", agent) }
      span.set("punch.request_id", context.request_id)
    end

    private def finish(span : Trace::Span, response : Response) : Nil
      return unless span.recording?

      status = response.status.code
      span.set("http.response.status_code", status)
      span.set("http.response.body.size", response.body.bytesize)
      span.error(status.to_s) if status >= 500 && !span.status.error?
      span.finish
    end

    private def respond(context : Context) : Response
      request = context.request
      warn_untrusted_forwarding(context)
      if request.path == HEALTH_PATH && {"GET", "HEAD"}.includes?(request.method)
        return health(context)
      end
      # Every value: a repeated header reads as one joined by ", ".
      if request.headers.get?("Content-Type").try(&.any?(&.downcase.lstrip.starts_with?("multipart/")))
        return Response.problem(:unsupported_media_type, context)
      end

      @handler.call(context)
    end

    # Forwarded headers from a peer that is not a trusted proxy usually mean
    # the proxy was not configured, and every client is counted as the proxy.
    private def warn_untrusted_forwarding(context : Context) : Nil
      return if context.forwarded? || !context.request.headers.has_key?("X-Forwarded-For")
      return if @warned_forwarded.swap(true)

      Log.warn { "X-Forwarded-For from #{context.client_ip}, which is not a trusted proxy: the header is ignored. If a proxy runs in front, add it to trusted_proxies. Logged once." }
    end

    # The failing checks' names and reasons go only to the machine itself
    # and the trusted proxies, which poll it; anyone else learns only that
    # the app is failing.
    private def health(context : Context) : Response
      return Response.json(:service_unavailable, %({"status":"draining"})) if draining?

      failures = @health_checks.compact_map do |name, check|
        (reason = check.call) ? {name, reason} : nil
      rescue ex
        {name, ex.message || ex.class.name}
      end
      return Response.json(:ok, %({"status":"ok"})) if failures.empty?

      client = context.client_ip
      inside = client.starts_with?("127.") || client == "::1" || context.config.trusted_proxies.includes?(client)
      body = inside ? {status: "failing", checks: failures.to_h}.to_json : %({"status":"failing"})
      Response.json(:service_unavailable, body)
    end

    private def write(http : ::HTTP::Server::Context, response : Response) : Nil
      output = http.response
      output.status = response.status
      response.headers.each { |name, values| output.headers[name] = values }
      if live = response.live
        # Chunked, flushed per event, until the stream ends.
        live.run(output)
        output.close
        return
      end
      out = output
      # 204 and 304 carry no body and no length (RFC 9110, 8.6).
      out.content_length = response.body.bytesize unless response.status.no_content? || response.status.not_modified?
      out.write(response.body.to_slice) unless http.request.method == "HEAD"
      out.close
    end
  end
end
