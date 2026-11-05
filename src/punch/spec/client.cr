module Punch::Spec
  # The app's `openapi.json`, embedded when the specs compile, relative to
  # where they run; `nil` without one. `Client` checks every response
  # against it.
  class_property openapi : String? = {{ read_file?("openapi.json") }}

  # A client for this example's app: the router over `Punch::Spec.db`,
  # checked against `Punch::Spec.openapi`.
  def self.client(**options) : Client
    Client.new(Routing::Router.new(db, openapi: openapi), **options)
  end

  # Raised by a `Client` when a request ended in an unhandled exception
  # (the 500 page is all a response shows): the request line and the
  # exception's class and message, with the exception itself as `cause`,
  # backtrace included. Pass `raise_errors: false` to a client that tests
  # the 500 page.
  class ServerError < Exception
  end

  # A response as the client received it, with the trace of its request.
  struct Response
    getter status : ::HTTP::Status
    getter headers : ::HTTP::Headers
    getter body : String
    # The unhandled exception behind a 500, with its backtrace; `nil` for
    # any other answer. A client that does not raise it (`raise_errors:
    # false`) keeps it here.
    getter exception : Exception?

    # Every span of the request, recorded in full; `nil` for `/up`, which
    # is not traced.
    def trace? : Trace::Finished?
      @trace
    end

    def initialize(@status : ::HTTP::Status, @headers : ::HTTP::Headers, @body : String, @trace : Trace::Finished?, @exception : Exception? = nil)
    end

    def trace : Trace::Finished
      @trace || raise "#{status.code} response without a trace: /up is not traced"
    end

    def json : JSON::Any
      JSON.parse(body)
    end

    # The body as parsed HTML, for `find` and `text` by CSS selector.
    def html : HTML
      HTML.new(body)
    end

    def content_type : String?
      headers["Content-Type"]?.try(&.split(';').first.strip.downcase)
    end

    # Whether this is a stored answer given again under an idempotency
    # key (`Idempotent-Replayed: true`).
    def replayed? : Bool
      headers[IdempotencyKeys::REPLAYED_HEADER]? == "true"
    end
  end

  # Endpoint specs without a socket: each request goes through
  # `HTTP::Server#process`, the same code as a real connection, minus the
  # bytes. Every span is recorded and returned with the response; nothing is
  # printed. Wide events go to `Punch::Spec.ops` once an example opened it.
  #
  # With an OpenAPI document (`Punch::Spec.openapi` by default), every
  # response is checked against it, the contract test for free: the status
  # must be documented for the operation, and the body must match its media
  # type and schema. A mismatch fails the example. HTML responses (pages)
  # are not part of the document and are not checked.
  #
  # ```
  # client = Punch::Spec.client
  # response = client.post(Invoices::Send.path(invoice_id: id), json: {recipient: "ann@example.org"})
  # response.status.should eq(HTTP::Status::OK)
  # response.trace.should have_span("Billing::Invoices::Queries.mark_sent")
  # ```
  class Client
    getter server : HTTP::Server
    getter contract : Contract?
    # Cookies the app has set, sent back with every later request, as a
    # browser would. Cleared by a `Max-Age=0` cookie.
    getter cookies = {} of String => String
    # Sent as `Accept-Language` with every request that sets none, as a
    # browser in that language would: `client.language = "de"`.
    property language : String?
    # Whether a request that ends in an unhandled exception raises
    # `ServerError`, with the exception as its cause, instead of returning
    # the 500 page. A spec that tests the 500 sets `false`; the exception
    # is then `Response#exception`.
    property? raise_errors : Bool

    def initialize(handler : HTTP::Handler | Routing::Router, *, openapi : String? = Spec.openapi,
                   config : HTTP::Config = HTTP::Config.new, @peer : String = "127.0.0.1",
                   @raise_errors : Bool = true)
      # As `serve` refuses to start: a route the probe patterns answer.
      if handler.is_a?(Routing::Router) && config.probes.enabled? &&
         !(conflicts = HTTP::Probes.conflicts(Routing.routes.map(&.template))).empty?
        raise ArgumentError.new("These routes look like what scanners ask for, so they would be answered 404 and their visitors banned: #{conflicts.join(", ")}. " \
                                "Rename them, or take the pattern out in app/setup.cr: Punch::HTTP::Probes.patterns = Punch::HTTP::Probes::Patterns.default.without(...) (lib/punch/docs/http.md).")
      end
      @exporter = Trace::MemoryExporter.new
      tracer = Trace::Tracer.new(exporters: [@exporter] of Trace::Exporter, events: [OpsEvents.new] of Trace::EventSink)
      call = case handler
             in Routing::Router then ->(context : HTTP::Context) { handler.as(Routing::Router).call(context) }
             in HTTP::Handler   then handler
             end
      @server = HTTP::Server.new(config, tracer, &call)
      @contract = openapi.try { |document| Contract.for(document) }
    end

    def get(path : String, *, query = nil, headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response
      request("GET", path, query: query, headers: headers, file: file, line: line)
    end

    # A page, as a browser asks for it (`Accept: text/html,…`).
    #
    # ```
    # response = client.visit(Invoices::ShowPage.href(invoice_id: id))
    # response.should have_element("h1", text: "Invoice A-42")
    # ```
    def visit(href : Href | String, *, query = nil, headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response
      headers = headers.try(&.dup) || ::HTTP::Headers.new
      headers["Accept"] ||= BROWSER_ACCEPT
      request("GET", href.to_s, query: query, headers: headers, file: file, line: line)
    end

    # A page as an agent reads it (`Accept: text/markdown`). A page that is
    # not agent-readable answers HTML.
    #
    # ```
    # response = client.read(Invoices::ShowPage.href(invoice_id: id))
    # response.body.should contain("# Invoice A-42")
    # ```
    def read(href : Href | String, *, query = nil, headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response
      headers = headers.try(&.dup) || ::HTTP::Headers.new
      headers["Accept"] ||= "text/markdown"
      request("GET", href.to_s, query: query, headers: headers, file: file, line: line)
    end

    # Sends a form as a browser does: `POST` to the action with a form
    # body, the action's `_method`, and a same-origin `Sec-Fetch-Site`.
    # *values* are checked against the Command's input like a form's
    # (`View#form`); *form* sends any fields, such as values that do not
    # parse. A Command that requires an idempotency key gets a new one, as
    # its form on a page would carry. With *stream*, it asks for Turbo
    # Stream actions as Turbo does (`Page.stream`).
    #
    # ```
    # response = client.submit(Customers::Create.action, {name: name, email: email})
    # response.should redirect_to(Customers::IndexPage.href)
    # client.submit(Customers::Create.action, form: {"email" => "nope"}).should have_field_error("email", "invalid_email")
    # client.submit(Customers::Create.action, {name: name, email: email}, stream: true).should have_stream_action(:prepend, "customers")
    # ```
    def submit(action : Action(C), values : NamedTuple? = nil, *, form : (Hash(String, String) | URI::Params)? = nil,
               stream : Bool = false, headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response forall C
      params = Input::Form.encode(C::Input, values)

      case form
      in Hash        then form.each { |key, value| params.add(key, value) }
      in URI::Params then form.each { |key, value| params.add(key, value) }
      in Nil
      end

      # The page writes a key into the form of a Command that requires one.
      if Routing.idempotency(C) == :required && !params.has_key?(IdempotencyKeys::FIELD)
        params.add(IdempotencyKeys::FIELD, Random::Secure.urlsafe_base64(18))
      end
      headers = headers.try(&.dup) || ::HTTP::Headers.new
      headers["Content-Type"] = "application/x-www-form-urlencoded"
      headers["Accept"] ||= stream ? TURBO_FORM_ACCEPT : BROWSER_ACCEPT
      headers["Sec-Fetch-Site"] ||= "same-origin"
      request("POST", action.url, body: params.to_s, headers: headers, file: file, line: line)
    end

    def head(path : String, *, query = nil, headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response
      request("HEAD", path, query: query, headers: headers, file: file, line: line)
    end

    {% for method in %w[post put patch delete] %}
      # With *json*, the value's JSON is the body and `Content-Type` is
      # `application/json`; *body* sends text as it is.
      def {{ method.id }}(path : String, *, json = nil, body : String? = nil, query = nil,
                          headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response
        request({{ method.upcase }}, path, json: json, body: body, query: query, headers: headers, file: file, line: line)
      end
    {% end %}

    # The language, the cookies, and, with cookies, the `Sec-Fetch-Site`
    # a browser sends along: without it the session cookie is refused on
    # a Command (`HTTP::CrossOrigin`).
    private def browser_headers(headers : ::HTTP::Headers) : ::HTTP::Headers
      @language.try { |language| headers["Accept-Language"] ||= language }
      if !@cookies.empty? && !headers.has_key?("Cookie")
        headers["Cookie"] = @cookies.join("; ") { |name, value| "#{name}=#{value}" }
      end
      headers["Sec-Fetch-Site"] ||= "same-origin" if headers.has_key?("Cookie") && !headers.has_key?("Origin")
      headers
    end

    # Any request. *query* is a Hash or NamedTuple of parameters; a nested
    # one is written in brackets, as a filter is read
    # (`query: {filter: {status: "sent"}}` is `filter[status]=sent`).
    def request(method : String, path : String, *, json = nil, body : String? = nil, query = nil,
                headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response
      headers = browser_headers(headers.try(&.dup) || ::HTTP::Headers.new)
      unless json.nil?
        body = json.to_json
        headers["Content-Type"] ||= "application/json"
      end
      target = query ? "#{path}#{path.includes?('?') ? '&' : '?'}#{encode(query)}" : path
      request = ::HTTP::Request.new(method, target, headers, body)
      response = @server.process(request, @peer)
      # A live page's stream is read with `live`, not here.
      response.live.try(&.discard)
      keep_cookies(response.headers)
      id = response.headers["X-Request-ID"]?
      trace = @exporter.traces.find { |finished| finished.root.trace_id.try(&.to_s) == id }
      result = Response.new(response.status, response.headers, response.body, trace, response.exception)
      if (raised = response.exception) && @raise_errors
        raise ServerError.new("#{method} #{request.path} raised #{raised.class}: #{raised.message}\n" \
                              "(the server answered 500; pass raise_errors: false to the client to test the 500 page)", cause: raised)
      end
      # A form's answers (303, the page again) are for browsers, outside
      # the document (docs/views.md).
      form = headers["Content-Type"]?.try(&.starts_with?("application/x-www-form-urlencoded"))
      if (contract = @contract) && !form
        violations = contract.check(method, request.path, result)
        unless violations.empty?
          ::fail("#{method} #{request.path} answered #{response.status.code}, which breaks the OpenAPI document:\n  " \
                 "#{violations.join("\n  ")}\nIf the code is right, the document is stale: run 'punch openapi'.", file, line)
        end
      end
      result
    end

    # Sends one request twice under one idempotency key, as a client
    # retrying after a lost answer would, and returns both answers. The
    # second should be the first, replayed.
    #
    # ```
    # first, again = client.twice("POST", Invoices::Send.path(invoice_id: id))
    # again.should be_replay_of(first)
    # ```
    def twice(method : String, path : String, *, json = nil, body : String? = nil, headers : ::HTTP::Headers? = nil,
              key : String = Random::Secure.urlsafe_base64(18), file = __FILE__, line = __LINE__) : {Response, Response}
      headers = headers.try(&.dup) || ::HTTP::Headers.new
      headers[IdempotencyKeys::HEADER] = key
      {request(method, path, json: json, body: body, headers: headers, file: file, line: line),
       request(method, path, json: json, body: body, headers: headers, file: file, line: line)}
    end

    # Delivers a webhook as a provider would: `POST` *body* to *path*,
    # signed with *secret* by the Standard Webhooks scheme
    # (`Punch::Webhook::Signature`): `webhook-id`, `webhook-timestamp`, and
    # `webhook-signature`. *id* is the delivery's ID (the provider's
    # idempotency key), *at* when it was signed; *headers* are added
    # last, to send what a provider adds or to break a signature on
    # purpose.
    #
    # ```
    # response = client.deliver_webhook(Payments::Receive.path, %({"type":"invoice.paid","invoice_id":7}), secret: SECRET)
    # response.status.should eq(HTTP::Status::NO_CONTENT)
    # client.deliver_webhook(path, body, secret: "whsec_wrong").status.should eq(HTTP::Status::UNAUTHORIZED)
    # ```
    def deliver_webhook(path : String, body : String, *, secret : String, id : String = "msg_#{Random::Secure.hex(12)}",
                        at : Time = Time.utc, headers : ::HTTP::Headers? = nil, file = __FILE__, line = __LINE__) : Response
      signed = Webhook::Signature.headers(secret, id, at, body)
      signed["Content-Type"] = "application/json"
      headers.try &.each { |name, values| signed[name] = values }
      request("POST", path, body: body, headers: signed, file: file, line: line)
    end

    # Signs *user_id* in: a session in `Punch::Spec.db`, its cookie in
    # this client. Returns the client, for
    # `Punch::Spec.client.sign_in(user.id)`.
    def sign_in(user_id : TypedID | Int64, *, method : String = "password", now : Time = Time.utc) : self
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      _, token = Spec.db.write { |db| Auth::Sessions.create(db, raw, method, now: now) }
      @cookies[Auth::COOKIE] = token.unwrap
      self
    end

    # Forgets every cookie, as a new browser would.
    def sign_out : self
      @cookies.clear
      self
    end

    private def keep_cookies(headers : ::HTTP::Headers) : Nil
      (headers.get?("Set-Cookie") || return).each do |line|
        cookie = ::HTTP::Cookie::Parser.parse_set_cookie(line) || next
        if cookie.max_age.try { |age| age <= Time::Span.zero } || cookie.value.empty?
          @cookies.delete(cookie.name)
        else
          @cookies[cookie.name] = cookie.value
        end
      end
    end

    private def encode(query) : String
      URI::Params.build { |params| add(params, nil, query) }
    end

    private def add(params : URI::Params::Builder, prefix : String?, values : Hash | NamedTuple) : Nil
      values.each { |key, value| add(params, prefix ? "#{prefix}[#{key}]" : key.to_s, value) }
    end

    private def add(params : URI::Params::Builder, key : String, value) : Nil
      params.add(key, value.to_s)
    end
  end

  # An OpenAPI document as a contract for responses: which statuses an
  # operation may answer, and the media type and schema of each body.
  class Contract
    @@cache = {} of String => Contract
    @@lock = Mutex.new

    # The contract of *document*, parsed once per run.
    def self.for(document : String) : Contract
      @@lock.synchronize { @@cache[document] ||= new(JSON.parse(document)) }
    end

    getter document : JSON::Any
    # Path templates split into segments, `nil` for `{parameter}`.
    @paths : Array({String, Array(String?)})

    def initialize(@document : JSON::Any)
      @paths = (document["paths"]?.try(&.as_h) || {} of String => JSON::Any).keys.map do |template|
        {template, segments(template).map { |segment| segment.starts_with?('{') ? nil : segment }}
      end
    end

    # What is wrong with *response* to *method* on *path*; empty when it
    # keeps the contract. A path the document does not have is not checked,
    # except that a problem must still be a `Punch.Problem`.
    def check(method : String, path : String, response : Response) : Array(String)
      # Pages are not part of the contract (docs/views.md).
      return [] of String if response.content_type.in?("text/html", "text/markdown")

      template = match(path)
      operation = template.try { |found| @document["paths"][found][method == "HEAD" ? "get" : method.downcase]? }
      return outside(response) unless operation

      responses = operation["responses"]
      documented = responses[response.status.code.to_s]? || responses["default"]? ||
                   return ["status #{response.status.code} is not documented; it documents #{responses.as_h.keys.join(", ")}"]
      return [] of String if method == "HEAD"

      content = documented["content"]?.try(&.as_h)
      return content(response, content) if content

      response.body.empty? ? [] of String : ["the document promises no body, got #{response.body.bytesize} bytes"]
    end

    # Outside the document's operations, only a problem has a schema.
    private def outside(response : Response) : Array(String)
      return [] of String unless response.content_type == "application/problem+json"

      problem = @document.dig?("components", "schemas", OpenAPI::PROBLEM) || return [] of String
      body(response, problem, "application/problem+json")
    end

    private def content(response : Response, content : Hash(String, JSON::Any)) : Array(String)
      type = response.content_type
      media = type ? content[type]? : nil
      unless type && media
        return ["Content-Type #{type || "(none)"} is not documented; it documents #{content.keys.join(", ")}"]
      end

      schema = media["schema"]? || return [] of String
      body(response, schema, type)
    end

    private def body(response : Response, schema : JSON::Any, type : String) : Array(String)
      value = begin
        JSON.parse(response.body)
      rescue JSON::ParseException
        return ["the body is not JSON (#{type})"]
      end
      JSONSchema.validate(value, schema, @document).map { |violation| "body #{violation}" }
    end

    # The template for *path*, literal segments winning over parameters,
    # earlier positions first, as the router matches.
    private def match(path : String) : String?
      parts = segments(path).map { |segment| URI.decode(segment) }
      candidates = @paths.select do |_, template|
        template.size == parts.size && template.each_with_index.all? { |segment, index| segment.nil? ? !parts[index].empty? : segment == parts[index] }
      end
      candidates.max_by? { |_, template| template.map { |segment| segment ? 1 : 0 } }.try(&.[0])
    end

    private def segments(path : String) : Array(String)
      path == "/" ? [] of String : path.lchop('/').split('/')
    end
  end
end
