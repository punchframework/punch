require "random/secure"

module Punch::HTTP
  # Returned by `Context#read_body` when the body exceeds the limit.
  struct BodyTooLarge
    getter limit : Int32

    def initialize(@limit : Int32)
    end
  end

  # One request, passed explicitly to everything that handles it:
  # fiber-scoped, never a thread-local.
  class Context
    REQUEST_ID = /\A[A-Za-z0-9._:\-]{1,128}\z/

    getter request : ::HTTP::Request
    getter config : Config
    # Taken from a trusted proxy's `X-Request-ID` if it is well formed,
    # otherwise the trace ID. Sent back in the response.
    getter request_id : String
    # The request's root span, which is also its wide event
    # (`docs/tracing.md`). `Punch::Trace::Span::NOOP` without a tracer.
    getter span : Trace::Span
    # The client's address: the peer, or, behind a trusted proxy, the
    # nearest address in `X-Forwarded-For` that is not a trusted proxy.
    getter client_ip : String
    getter started_at : Time::Instant
    # Where the request's trace goes; `nil` for `/up`.
    getter tracer : Trace::Tracer?
    getter? https : Bool
    # Whether the request came through a trusted proxy.
    getter? forwarded : Bool
    # Who the request acts for, once an operation that takes an actor has
    # authenticated it (`docs/auth.md`).
    property principal : Auth::Principal?
    # A session or token whose last-seen time is due, written after a
    # Query's read transaction.
    # :nodoc:
    property touch : Auth::Session | Auth::APIToken?
    # A form the Command refused, while the page that holds it is rendered
    # again (`Punch::Submissions`).
    property submission : Submission?
    # The rate limits checked so far, for the response's headers.
    # :nodoc:
    property rate_limits : RateLimits::State?
    # `Set-Cookie` values for the response.
    getter cookies : Array(String) { [] of String }
    # Whether the page answers as markdown: it is agent-readable and the
    # client prefers `text/markdown`. Set by the router.
    property? markdown = false
    # Whether the page is agent-readable and answers HTML, so its head
    # names the markdown as an alternate. Set by the router.
    property? markdown_alternate = false
    # Where a live page's stream starts: the live hub's position before
    # the page's read (`Punch::Live`). Set by the router.
    property live_position : String?
    # The live page's path when the request was not for it: a page shown
    # again after a refused form.
    property live_path : String?
    @locale : Locale?
    # Whether the locale came from `Accept-Language`, so the response
    # varies by it.
    getter? negotiated = false

    # The locale the response is rendered in: the actor's stored one once
    # the operation loaded it, else the best match for `Accept-Language`,
    # else the default.
    def locale : Locale
      @locale ||= begin
        @negotiated = request.headers.has_key?("Accept-Language")
        I18n.negotiate(request.headers["Accept-Language"]?)
      end
    end

    # The actor's stored locale, which wins over `Accept-Language`.
    def locale=(locale : Locale) : Locale
      @negotiated = false
      @locale = locale
    end

    # Whether anything rendered in a locale yet.
    def localized? : Bool
      !@locale.nil?
    end

    # With *tracer*, the request starts a trace, continuing a trusted
    # proxy's `traceparent`.
    def initialize(@request : ::HTTP::Request, peer : String, @config : Config,
                   @started_at : Time::Instant = Time.instant, tracer : Trace::Tracer? = nil)
      @client_ip, from_proxy = Context.client(request.headers, peer, config.trusted_proxies)
      @forwarded = from_proxy
      @https = from_proxy && request.headers["X-Forwarded-Proto"]?.try(&.split(',').last.strip.downcase) == "https"
      parent = request.headers["traceparent"]?.try { |header| Trace::SpanContext.parse?(header) } if from_proxy
      @tracer = tracer
      @span = tracer ? tracer.start(request.method, :server, parent) : Trace::Span::NOOP
      forwarded_id = request.headers["X-Request-ID"]? if from_proxy
      @request_id = if forwarded_id && forwarded_id.valid_encoding? && REQUEST_ID.matches?(forwarded_id)
                      forwarded_id
                    else
                      @span.trace_id.try(&.to_s) || Random::Secure.hex(16)
                    end
    end

    # Whether a cookie is waiting to be set, without creating the list.
    def cookies? : Bool
      !!@cookies.try(&.empty?.!)
    end

    # Reads the request body, at most *limit* bytes. A declared
    # `Content-Length` above the limit is refused before anything is read.
    def read_body(limit : Int32 = @config.max_body_size) : String | BodyTooLarge
      if (length = request.content_length) && length > limit
        return BodyTooLarge.new(limit)
      end

      body = request.body || return ""
      buffer = IO::Memory.new
      copied = IO.copy(body, buffer, limit + 1)
      copied > limit ? BodyTooLarge.new(limit) : buffer.to_s
    end

    # The client's address, and whether the request came through a trusted
    # proxy: what `client_ip` and `forwarded?` say, for code that runs
    # before a context exists (`Probes::Guard`).
    def self.client(headers : ::HTTP::Headers, peer : String, proxies : TrustedProxies) : {String, Bool}
      return {peer, false} unless proxies.includes?(peer)

      {forwarded_client(headers, peer, proxies), true}
    end

    # Walks `X-Forwarded-For` from the right, skipping trusted proxies; the
    # first other address is the client. Entries to the left of it were
    # written by the client and may be forged. An entry that does not parse
    # stops the walk at the last good address.
    protected def self.forwarded_client(headers : ::HTTP::Headers, peer : String, proxies : TrustedProxies) : String
      values = headers.get?("X-Forwarded-For") || return peer
      client = peer
      values.join(',').split(',').reverse_each do |entry|
        address = TrustedProxies.canonical(entry.strip) || return client
        client = address
        return client unless proxies.includes?(address)
      end
      client
    end
  end
end
