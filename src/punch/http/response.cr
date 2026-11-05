require "../view/safe_html"

module Punch::HTTP
  # What a handler returns: status, headers, and the whole body. The kernel
  # sends it with `Content-Length` in one piece, never chunked (a chunked
  # response cost 40 ms in delayed ACKs). The one exception is a live page's
  # stream (`live`), which stays open.
  struct Response
    getter status : ::HTTP::Status
    getter headers : ::HTTP::Headers
    getter body : String
    # A live page's server-sent events, written after the headers until
    # the stream ends (`Punch::Live`).
    getter live : Live::Connection?
    # The unhandled exception the server turned into this 500, so the spec
    # client can show it (`Punch::Spec::Client`); `nil` otherwise. Never
    # written to the wire.
    getter exception : Exception?

    # Any body as it is: for HTML use `Response.html`, which takes only a
    # `SafeHTML`; a `Content-Type: text/html` set here by hand sends
    # whatever the string holds.
    def initialize(@status : ::HTTP::Status, @body : String = "", headers : ::HTTP::Headers? = nil, @live : Live::Connection? = nil,
                   @exception : Exception? = nil)
      @headers = headers || ::HTTP::Headers.new
    end

    # A live page's stream: `text/event-stream`, never cached or buffered
    # by a proxy.
    def self.live(connection : Live::Connection) : self
      new(:ok, "", ::HTTP::Headers{
        "Content-Type"      => "#{Live::MEDIA_TYPE}; charset=utf-8",
        "Cache-Control"     => "no-store",
        "X-Accel-Buffering" => "no",
      }, connection)
    end

    def self.json(status : ::HTTP::Status, body : String) : self
      new(status, body, ::HTTP::Headers{"Content-Type" => "application/json"})
    end

    # A rendered page (`Punch::HTMLView.render`). Only a `SafeHTML` can be
    # sent as HTML, so nothing unescaped reaches a browser by accident.
    def self.html(status : ::HTTP::Status, html : SafeHTML) : self
      new(status, html.value, ::HTTP::Headers{"Content-Type" => "text/html; charset=utf-8"})
    end

    # A page as markdown for agents (`Punch::View.markdown`), GitHub
    # Flavored (RFC 7763).
    def self.markdown(status : ::HTTP::Status, body : String) : self
      new(status, body, ::HTTP::Headers{"Content-Type" => "text/markdown; charset=utf-8; variant=GFM"})
    end

    # Turbo Stream actions (`Punch::TurboStream#render`), which Turbo applies
    # to the page it shows.
    def self.turbo_stream(html : SafeHTML) : self
      new(:ok, html.value, ::HTTP::Headers{"Content-Type" => "text/vnd.turbo-stream.html; charset=utf-8"})
    end

    def self.text(status : ::HTTP::Status, body : String) : self
      new(status, body, ::HTTP::Headers{"Content-Type" => "text/plain; charset=utf-8"})
    end

    # An RFC 9457 problem: `type` is `about:blank`, so `title` is the
    # status phrase; `code` names the problem in snake_case (the status by
    # default, such as `not_found`), and `request_id` ties it to the log.
    # The block writes extension members. Codes, never sentences: messages
    # are rendered from codes at the edge.
    def self.problem(status : ::HTTP::Status, request_id : String? = nil, code : String = status.to_s.downcase, & : JSON::Builder ->) : self
      body = JSON.build do |json|
        json.object do
          json.field "type", "about:blank"
          json.field "title", status.description
          json.field "status", status.code
          json.field "code", code
          json.field "request_id", request_id if request_id
          yield json
        end
      end
      new(status, body, ::HTTP::Headers{"Content-Type" => "application/problem+json"})
    end

    def self.problem(status : ::HTTP::Status, request_id : String? = nil, code : String = status.to_s.downcase) : self
      problem(status, request_id, code) { }
    end

    # A problem for *context*'s request: its request ID, and as `detail`
    # the problem's message in the request's locale (`problems.<code>`),
    # filled in with *params*.
    def self.problem(status : ::HTTP::Status, context : Context, code : String = status.to_s.downcase,
                     params : Hash(String, Invalid::Param) = {} of String => Invalid::Param, & : JSON::Builder ->) : self
      detail = context.locale.problem?(code, params)
      problem(status, context.request_id, code) do |json|
        json.field "detail", detail if detail
        yield json
      end
    end

    # :ditto:
    def self.problem(status : ::HTTP::Status, context : Context, code : String = status.to_s.downcase,
                     params : Hash(String, Invalid::Param) = {} of String => Invalid::Param) : self
      problem(status, context, code, params) { }
    end
  end
end
