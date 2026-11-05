require "http/client"

module Punch::OTLP
  # Posts export requests to one URL, from one fiber at a time. Retries
  # what OTLP calls retryable (429, 502, 503, 504, and failed connections)
  # with growing pauses, honouring `Retry-After`, until *deadline*; drops
  # the rest. Failures are logged at most once a minute. After `hurry`
  # (shutdown), every request is tried once.
  class Sender
    Log = ::Log.for("punch.otlp")

    RETRYABLE = {429, 502, 503, 504}

    @client : ::HTTP::Client?
    @last_logged : Time::Instant?
    @hurry = Atomic(Bool).new(false)
    # Closed by `hurry`, which ends a pause between attempts.
    @wake = Channel(Nil).new

    def initialize(@url : URI, @headers : Headers, @timeout : Time::Span)
    end

    # Whether the receiver took the request. *body* is JSON.
    def post(body : String, deadline : Time::Instant) : Bool
      pause = 1.second
      loop do
        status, retry_after = attempt(body)
        return true if status && 200 <= status < 300

        unless status.nil? || RETRYABLE.includes?(status)
          warn("#{@url}: answered #{status}; dropped")
          return false
        end
        pause = retry_after || pause
        if @hurry.get || Time.instant + pause > deadline
          warn("#{@url}: #{status ? "answered #{status}" : "unreachable"}; gave up and dropped")
          return false
        end
        select
        when @wake.receive?
        when timeout(pause)
        end
        pause = Math.min(pause * 2, 30.seconds)
      end
    end

    # Stops retrying: the process is shutting down.
    def hurry : Nil
      @hurry.set(true)
      @wake.close
    end

    def close : Nil
      @client.try(&.close)
      @client = nil
    end

    # The status, or `nil` when the connection failed, and how long the
    # receiver asked to wait.
    private def attempt(body : String) : {Int32?, Time::Span?}
      response = client.post(@url.request_target, headers: request_headers, body: body)
      retry_after = response.headers["Retry-After"]?.try(&.to_i?).try(&.clamp(0, 300).seconds)
      partial(response) if response.success?
      {response.status_code, retry_after}
    rescue ex : IO::Error | Socket::Error | OpenSSL::Error
      close
      Log.debug(exception: ex) { "#{@url}: request failed" }
      {nil, nil}
    end

    # A receiver that took the request may still have rejected some of it.
    private def partial(response : ::HTTP::Client::Response) : Nil
      body = response.body
      return if body.empty? || !body.includes?("rejected")

      warn("#{@url}: accepted in part: #{body[0, 300]}")
    end

    private def client : ::HTTP::Client
      @client ||= ::HTTP::Client.new(@url).tap do |client|
        client.connect_timeout = @timeout
        client.read_timeout = @timeout
        client.write_timeout = @timeout
      end
    end

    private def request_headers : ::HTTP::Headers
      headers = ::HTTP::Headers{"Content-Type" => "application/json", "User-Agent" => "punch/#{Punch::VERSION}"}
      @headers.pairs.each { |name, value| headers[name] = value }
      headers
    end

    private def warn(message : String) : Nil
      now = Time.instant
      return if (last = @last_logged) && now - last < 1.minute

      @last_logged = now
      Log.warn { message }
    end
  end
end
