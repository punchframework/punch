module Punch::Spec
  # A live page's stream as a spec reads it (`Client#live`): each message
  # is the Turbo Stream actions of one server-sent event, ready for
  # `have_stream_action`.
  #
  # ```
  # live = client.live(Invoices::IndexPage.href)
  # client.submit(Invoices::Send.action(invoice_id: id))
  # live.next.should have_stream_action(:replace, id)
  # live.close
  # ```
  class LiveStream
    getter response : Response
    # The `id:` of the last message read: what a browser sends back as
    # `Last-Event-ID` when it reconnects.
    getter last_event_id : String?
    @reader : IO::FileDescriptor?
    @connection : Live::Connection?
    @done = Channel(Nil).new(1)

    def initialize(@response : Response, connection : Live::Connection?)
      @connection = connection
      return unless connection

      reader, writer = IO.pipe
      @reader = reader
      spawn do
        connection.run(writer)
      ensure
        writer.close rescue nil
        @done.send(nil)
      end
      Fiber.yield
    end

    def status : ::HTTP::Status
      response.status
    end

    # Whether the stream opened: refused ones answer like the page would.
    def open? : Bool
      !@connection.nil?
    end

    # The actions of the next message, waiting at most *timeout*; raises
    # when none comes or the stream ended.
    def next(timeout : Time::Span = 2.seconds) : String
      next?(timeout) || raise "No live message within #{timeout} (or the stream ended)"
    end

    # The actions of the next message, or `nil` when none comes within
    # *timeout* or the stream ended. Keepalive comments are skipped.
    def next?(timeout : Time::Span = 200.milliseconds) : String?
      reader = @reader || return
      reader.read_timeout = timeout
      data = [] of String
      while line = reader.gets(chomp: true)
        if line.empty?
          return data.join('\n') + "\n" unless data.empty?
        elsif line.starts_with?("data: ")
          data << line.lchop("data: ")
        elsif line.starts_with?("id: ")
          @last_event_id = line.lchop("id: ")
        end
      end
      nil
    rescue IO::TimeoutError
      nil
    end

    # Whether the server ended the stream: its viewer lost access, or the
    # hub closed.
    def ended?(timeout : Time::Span = 1.second) : Bool
      return true unless @connection

      select
      when @done.receive?
        @done.close
        true
      when timeout(timeout)
        false
      end
    rescue Channel::ClosedError
      true
    end

    # Ends the stream, as a browser leaving the page does.
    def close : Nil
      @connection.try(&.stop) rescue nil
      @reader.try(&.close) rescue nil
    end
  end

  class Client
    # Opens a live page's stream as Turbo's `<turbo-stream-source>` does
    # (`Accept: text/event-stream`, the session's cookie), with
    # *last_event_id* as a reconnecting browser sends it. The stream runs
    # in a fiber; read it with `next`, end it with `close`. A refused one
    # answers like the page (`status`).
    def live(href : Href | String, *, last_event_id : String? = nil, headers : ::HTTP::Headers? = nil) : LiveStream
      headers = headers.try(&.dup) || ::HTTP::Headers.new
      headers["Accept"] = Live::MEDIA_TYPE
      headers["Last-Event-ID"] = last_event_id if last_event_id
      @language.try { |language| headers["Accept-Language"] ||= language }
      if !@cookies.empty? && !headers.has_key?("Cookie")
        headers["Cookie"] = @cookies.join("; ") { |name, value| "#{name}=#{value}" }
      end
      response = @server.process(::HTTP::Request.new("GET", href.to_s, headers), @peer)
      id = response.headers["X-Request-ID"]?
      trace = @exporter.traces.find { |finished| finished.root.trace_id.try(&.to_s) == id }
      LiveStream.new(Response.new(response.status, response.headers, response.body, trace), response.live)
    end
  end
end
