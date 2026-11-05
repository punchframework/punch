require "../spec_helper"

module RoutingSpec
  struct Empty
    include Punch::Input
  end

  @[Punch::Status(404)]
  struct NotFound
    include JSON::Serializable

    getter error = "not_found"

    def initialize
    end
  end

  @[Punch::Status(200)]
  struct Echo
    include JSON::Serializable

    getter operation : String
    getter handle : String
    getter values : Hash(String, String)

    def initialize(@operation, @handle, @values = {} of String => String)
    end
  end

  enum Provider
    Stripe
    GitHub
  end

  module Invoices
    struct ID < Punch::TypedID
    end

    @[Punch::Public]
    struct Index < Punch::Query
      struct Input
        include Punch::Input

        getter page : Int32 = 1
      end

      def call(input : Input, db : Punch::Reader) : Echo
        Echo.new("index", db.class.name, {"page" => input.page.to_s})
      end
    end

    @[Punch::Public]
    struct Show < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : ID
      end

      alias Result = Echo | NotFound

      def call(input : Input, db : Punch::Reader) : Result
        return NotFound.new if input.invoice_id.value > 1000

        Echo.new("show", db.class.name, {"invoice_id" => input.invoice_id.to_s})
      end
    end

    @[Punch::Public]
    struct Export < Punch::Query
      alias Input = Empty

      def call(input : Input, db : Punch::Reader) : Echo
        Echo.new("export", db.class.name)
      end
    end

    @[Punch::Status(201)]
    struct Created
      include JSON::Serializable

      getter number : String

      def initialize(@number)
      end
    end

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter number : Punch::NonEmptyString
      end

      def call(input : Input, db : Punch::Writer) : Created
        Created.new(input.number.value)
      end
    end

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Update < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : ID

        getter note : String?
      end

      def call(input : Input, db : Punch::Writer) : Echo
        Echo.new("update", db.class.name, {"note" => input.note.to_s})
      end
    end

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Destroy < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : ID
      end

      def call(input : Input, db : Punch::Writer) : Nil
      end
    end

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct SendReminder < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : ID
      end

      def call(input : Input, db : Punch::Writer) : Echo
        Echo.new("send_reminder", db.class.name)
      end
    end
  end

  module Customers::Invoices
    @[Punch::Public]
    struct Index < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter customer_id : RoutingSpec::Invoices::ID
      end

      def call(input : Input, db : Punch::Reader) : Echo
        Echo.new("customer_invoices", db.class.name, {"customer_id" => input.customer_id.to_s})
      end
    end
  end

  module Reports
    @[Punch::Public]
    struct Show < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter slug : Punch::Slug
        @[Punch::PathParam]
        getter year : Int32
      end

      def call(input : Input, db : Punch::Reader) : Echo
        Echo.new("report", db.class.name, {"slug" => input.slug.value, "year" => input.year.to_s})
      end
    end
  end

  @[Punch::Route("POST", "/hooks/:provider")]
  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Webhook < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter provider : Provider
    end

    def call(input : Input, db : Punch::Writer) : Echo
      Echo.new("webhook", db.class.name, {"provider" => input.provider.to_s})
    end
  end

  # Reads the body as received, for a signature: only path parameters
  # are parsed, the body is its own.
  @[Punch::Route("POST", "/raw_hooks")]
  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct RawHook < Punch::Command
    struct Input
      include Punch::Input

      getter name : String?
    end

    def call(input : Input, db : Punch::Writer, request : Punch::RawRequest) : Echo
      Echo.new("raw_hook", db.class.name, {"body" => request.body, "type" => request.header("content-type").to_s, "name" => input.name.to_s})
    end
  end

  @[Punch::BodyLimit(2048)]
  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Import < Punch::Command
    struct Input
      include Punch::Input

      getter rows : Array(String)
    end

    def call(input : Input, db : Punch::Writer) : Echo
      Echo.new("import", db.class.name, {"rows" => input.rows.size.to_s})
    end
  end
end

private ROUTER = Punch::Routing::Router.new(Punch::Database.memory)

private def request(method : String, path : String, body : String? = nil, content_type = "application/json") : Punch::HTTP::Response
  headers = HTTP::Headers.new
  headers["Content-Type"] = content_type if body
  request = HTTP::Request.new(method, path, headers, body)
  context = Punch::HTTP::Context.new(request, "127.0.0.1", Punch::HTTP::Config.new(max_body_size: 1024))
  ROUTER.call(context)
end

# Routes one request inside a recorded trace, as the server would.
private def traced(method : String, path : String, body : String? = nil) : Punch::Trace::Finished
  exporter = Punch::Trace::MemoryExporter.new
  tracer = Punch::Trace::Tracer.new(exporters: [exporter] of Punch::Trace::Exporter, events: [] of Punch::Trace::EventSink)
  headers = HTTP::Headers.new
  headers["Content-Type"] = "application/json" if body
  context = Punch::HTTP::Context.new(HTTP::Request.new(method, path, headers, body), "127.0.0.1", Punch::HTTP::Config.new, tracer: tracer)
  Punch::Trace.with(context.span) { ROUTER.call(context) }
  context.span.finish
  exporter.traces.first
end

private def json(response : Punch::HTTP::Response) : JSON::Any
  JSON.parse(response.body)
end

private def route(operation : String) : Punch::Routing::Route
  Punch::Routing.routes.find(&.operation.==(operation)) || raise "no route for #{operation}"
end

describe Punch::Routing do
  describe "derivation" do
    it "turns the namespace into the path and reserved names into REST shapes" do
      {
        "RoutingSpec::Invoices::Index"        => {"GET", "/routing_spec/invoices"},
        "RoutingSpec::Invoices::Show"         => {"GET", "/routing_spec/invoices/:invoice_id"},
        "RoutingSpec::Invoices::Create"       => {"POST", "/routing_spec/invoices"},
        "RoutingSpec::Invoices::Update"       => {"PATCH", "/routing_spec/invoices/:invoice_id"},
        "RoutingSpec::Invoices::Destroy"      => {"DELETE", "/routing_spec/invoices/:invoice_id"},
        "RoutingSpec::Invoices::Export"       => {"GET", "/routing_spec/invoices/export"},
        "RoutingSpec::Invoices::SendReminder" => {"POST", "/routing_spec/invoices/:invoice_id/send_reminder"},
      }.each do |operation, (method, template)|
        found = route(operation)
        {found.method, found.template}.should eq({method, template})
      end
    end

    it "places an ID after the namespace segment it names" do
      route("RoutingSpec::Customers::Invoices::Index").template.should eq("/routing_spec/customers/:customer_id/invoices")
    end

    it "appends other path parameters in declaration order" do
      route("RoutingSpec::Reports::Show").template.should eq("/routing_spec/reports/:slug/:year")
    end

    it "takes an override from @[Punch::Route]" do
      found = route("RoutingSpec::Webhook")
      {found.method, found.template}.should eq({"POST", "/hooks/:provider"})
    end

    it "derives an operation ID from the name" do
      route("RoutingSpec::Invoices::SendReminder").operation_id.should eq("routing_spec.invoices.send_reminder")
    end
  end

  describe "typed URL helpers" do
    it "fills path parameters" do
      id = RoutingSpec::Invoices::ID.parse(42).as(RoutingSpec::Invoices::ID)
      RoutingSpec::Invoices::SendReminder.path(invoice_id: id).should eq("/routing_spec/invoices/42/send_reminder")
      RoutingSpec::Invoices::Index.path.should eq("/routing_spec/invoices")
      RoutingSpec::Webhook.path(provider: RoutingSpec::Provider::GitHub).should eq("/hooks/git_hub")
    end

    it "escapes values" do
      slug = Punch::Slug.parse("q3-report").as(Punch::Slug)
      RoutingSpec::Reports::Show.path(slug: slug, year: 2026).should eq("/routing_spec/reports/q3-report/2026")
    end

    it "produces paths that route back to the same operation" do
      id = RoutingSpec::Invoices::ID.parse(7).as(RoutingSpec::Invoices::ID)
      json(request("GET", RoutingSpec::Invoices::Show.path(invoice_id: id)))["operation"].should eq("show")
      json(request("POST", RoutingSpec::Webhook.path(provider: RoutingSpec::Provider::GitHub)))["values"]["provider"].should eq("GitHub")
    end
  end

  describe Punch::Routing::Router do
    it "runs a Query with a Reader and a Command with a Writer" do
      json(request("GET", "/routing_spec/invoices?page=3")).should eq(JSON.parse(%({"operation":"index","handle":"Punch::Reader","values":{"page":"3"}})))
      json(request("POST", "/routing_spec/invoices/5/send_reminder"))["handle"].should eq("Punch::Writer")
    end

    it "prefers a literal segment over a parameter" do
      json(request("GET", "/routing_spec/invoices/export"))["operation"].should eq("export")
      json(request("GET", "/routing_spec/invoices/9"))["operation"].should eq("show")
    end

    it "renders result statuses, and 204 for nil" do
      request("POST", "/routing_spec/invoices", %({"number": "INV-1"})).status.code.should eq(201)
      request("GET", "/routing_spec/invoices/5000").status.code.should eq(404)
      response = request("DELETE", "/routing_spec/invoices/5")
      response.status.code.should eq(204)
      response.body.should be_empty
    end

    it "answers 422 with every error" do
      response = request("PATCH", "/routing_spec/invoices/5", %({"note": 5}))
      response.status.code.should eq(422)
      response.headers["Content-Type"].should eq("application/problem+json")
      errors = json(response)["errors"].as_a.map { |error| {error["path"], error["code"]} }
      errors.should eq([{JSON.parse(%(["note"])), JSON::Any.new("expected_string")}])
    end

    it "answers 404 when a path parameter does not parse, whatever the body" do
      response = request("PATCH", "/routing_spec/invoices/0", %({"note": 5}))
      response.status.code.should eq(404)
      json(response)["code"].should eq("not_found")
    end

    it "renders a failure result as Problem Details, with its fields as extension members" do
      response = request("GET", "/routing_spec/invoices/5000")
      response.headers["Content-Type"].should eq("application/problem+json")
      body = json(response).as_h
      body.reject("request_id").should eq(JSON.parse(%({"type": "about:blank", "title": "Not Found", "status": 404, "code": "not_found", "detail": "There is nothing here.", "error": "not_found"})).as_h)
    end

    it "gives rejections the code invalid_input" do
      body = json(request("PATCH", "/routing_spec/invoices/5", %({"note": 5})))
      {body["type"], body["status"], body["code"]}.should eq({"about:blank", 422, "invalid_input"})
      body["errors"][0].as_h.keys.should eq(%w[path code params message])
    end

    it "names framework problems by their status" do
      json(request("GET", "/nope"))["code"].should eq("not_found")
      json(request("PUT", "/routing_spec/invoices/5"))["code"].should eq("method_not_allowed")
      json(request("POST", "/routing_spec/invoices", "x", "text/plain"))["code"].should eq("unsupported_media_type")
    end

    it "serves the embedded OpenAPI document when given one" do
      router = Punch::Routing::Router.new(Punch::Database.memory, openapi: %({"openapi": "3.2.0"}))
      context = Punch::HTTP::Context.new(HTTP::Request.new("GET", "/openapi.json"), "127.0.0.1", Punch::HTTP::Config.new)
      response = router.call(context)
      {response.status.code, response.headers["Content-Type"], response.body}.should eq({200, "application/json", %({"openapi": "3.2.0"})})
      request("GET", "/openapi.json").status.code.should eq(404) # not given one
    end

    it "takes path parameters from the path only" do
      json(request("GET", "/routing_spec/customers/12/invoices?customer_id=99"))["values"]["customer_id"].should eq("12")
    end

    it "decodes path segments" do
      json(request("GET", "/routing_spec/reports/q3%2Dreport/2026"))["values"]["slug"].should eq("q3-report")
      request("GET", "/routing_spec/reports/a%2Fb/2026").status.code.should eq(404) # not a slug
    end

    it "answers 404 for unknown paths, empty segments, and trailing slashes" do
      ["/nope", "/routing_spec/invoices/", "/routing_spec//invoices", "/routing_spec/invoices/5/send_reminder/x"].each do |path|
        request("GET", path).status.code.should eq(404)
      end
    end

    it "answers 405 with Allow for a known path and an unknown method" do
      response = request("PUT", "/routing_spec/invoices/5")
      response.status.code.should eq(405)
      response.headers["Allow"].should eq("DELETE, GET, HEAD, PATCH")
    end

    it "answers HEAD with the GET route" do
      request("HEAD", "/routing_spec/invoices").status.code.should eq(200)
    end

    it "requires JSON for a Command with a body" do
      request("POST", "/routing_spec/invoices", %({"number": "INV-1"}), "text/plain").status.code.should eq(415)
      request("POST", "/routing_spec/invoices", %({"number": "INV-1"}), "application/vnd.api+json; charset=utf-8").status.code.should eq(201)
      request("POST", "/routing_spec/invoices/5/send_reminder").status.code.should eq(200)
    end

    it "hands a Command that asks for it the body and headers as received" do
      body = %({ "name" :"raw",  "extra": [1]})
      values = json(request("POST", "/raw_hooks", body))["values"]
      values.should eq(JSON.parse({body: body, type: "application/json", name: ""}.to_json))
      # Any content type, and a body that is not JSON.
      form = json(request("POST", "/raw_hooks", "name=raw", "application/x-www-form-urlencoded"))["values"]
      {form["body"], form["name"]}.should eq({"name=raw", ""})
      json(request("POST", "/raw_hooks"))["values"]["body"].should eq("")
      Punch::RawRequest.new("secret", HTTP::Headers.new).inspect.should eq("#<Punch::RawRequest 6 bytes>")
    end

    it "applies the body limit, raised per Command" do
      big = %({"rows": [#{(["\"#{"x" * 10}\""] * 100).join(',')}]})
      request("POST", "/routing_spec/import", big).status.code.should eq(200)
      request("POST", "/routing_spec/invoices", %({"number": "#{"x" * 1100}"})).status.code.should eq(413)
    end

    it "routes in parallel" do
      results = Channel(Bool).new
      16.times do |fiber|
        spawn do
          ok = (1..100).all? do |number|
            id = fiber * 1000 + number
            body = json(request("GET", "/routing_spec/customers/#{id}/invoices"))
            body["values"]["customer_id"] == id.to_s
          end
          results.send(ok)
        end
      end
      16.times { results.receive.should be_true }
    end

    describe "tracing" do
      it "names the request by its route and records the operation and its outcome" do
        trace = traced("GET", "/routing_spec/invoices/42")
        root = trace.root
        root.name.should eq("GET /routing_spec/invoices/:invoice_id")
        root["http.route"].should eq("/routing_spec/invoices/:invoice_id")
        root["punch.operation"].should eq("RoutingSpec::Invoices::Show")
        root["punch.outcome"].should eq("echo")
        trace.should have_span("input")
        trace.should have_span("memory read", "db.namespace": "memory")
        traced("GET", "/routing_spec/invoices/4242").root["punch.outcome"].should eq("not_found")
      end

      it "records a rejection on the wide event, without the values" do
        trace = traced("POST", "/routing_spec/invoices", %({"number": ""}))
        trace.root["punch.outcome"].should eq("invalid_input")
        trace.root["punch.input.errors"].should eq(1)
        trace.should_not have_span("memory write")
      end

      it "records the writer wait of a Command" do
        trace = traced("POST", "/routing_spec/invoices", %({"number": "INV-1"}))
        trace["memory write"]["punch.db.writer_wait_ms"].as(Float64).should be >= 0.0
        trace.root["punch.db.writer_wait_ms"].as(Float64).should be >= 0.0
      end

      it "leaves the name at the method when no route matches" do
        traced("GET", "/nowhere").root.name.should eq("GET")
      end
    end
  end
end
