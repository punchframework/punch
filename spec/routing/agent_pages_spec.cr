require "../spec_helper"
require "../support/auth_schema"

module AgentPagesSpec
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(200)]
  struct Invoice
    include JSON::Serializable

    getter id : Int64
    getter number : String

    def initialize(@id, @number)
    end
  end

  # Chrome may hold raw HTML on a page agents read: markdown leaves it out.
  struct Layout
    include Punch::Component

    def initialize(@title : String)
    end

    def view(v : Punch::View, &) : Nil
      v.document(@title) do
        v.chrome { |chrome| chrome.nav { chrome.raw Punch::SafeHTML.trusted(%(<svg aria-hidden="true"></svg>)) } }
        v.main { yield }
      end
    end
  end

  @[Punch::Status(200)]
  struct InvoiceView
    include Punch::Component

    def initialize(@invoice : Invoice)
    end

    def view(v : Punch::View) : Nil
      v.render(Layout.new("Invoice #{@invoice.number}")) do
        v.h1 "Invoice #{@invoice.number}"
        v.p do
          v.text "Back to "
          v.a "all invoices", href: Invoices::IndexPage.href
        end
      end
    end
  end

  # Raw HTML outside chrome: fine on a page only people see.
  struct Chart
    include Punch::Component

    def view(v : Punch::HTMLView) : Nil
      v.document("Dashboard") { v.raw Punch::SafeHTML.trusted("<svg></svg>") }
    end
  end

  module Invoices
    @[Punch::Public]
    struct Show < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : Int64
      end

      def call(input : Input, db : Punch::Reader) : Invoice | NotFound
        input.invoice_id == 1 ? Invoice.new(1, "A-1") : NotFound.new
      end
    end

    @[Punch::AgentReadable]
    @[Punch::Public]
    struct ShowPage < Punch::Page
      alias Input = Show::Input

      def call(input : Input, db : Punch::Reader) : InvoiceView | NotFound
        case invoice = Show.new.call(input, db)
        in NotFound then invoice
        in Invoice  then InvoiceView.new(invoice)
        end
      end
    end

    @[Punch::AgentReadable(entry: true)]
    @[Punch::Public]
    struct IndexPage < Punch::Page
      struct Input
        include Punch::Input

        getter page : Int32 = 1
      end

      def call(input : Input, db : Punch::Reader) : InvoiceView
        InvoiceView.new(Invoice.new(input.page.to_i64, "page #{input.page}"))
      end
    end

    @[Punch::AgentReadable]
    @[Punch::Public]
    struct DraftsPage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : InvoiceView
        InvoiceView.new(Invoice.new(0, "drafts of #{actor.principal.user_id}"))
      end
    end
  end

  @[Punch::Public]
  struct DashboardPage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Chart
      Chart.new
    end
  end

  MARKDOWN = HTTP::Headers{"Accept" => "text/markdown"}

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end
end

describe Punch::AgentReadable do
  it "marks the route" do
    routes = Punch::Routing.routes.select(&.operation.starts_with?("AgentPagesSpec::")).to_h { |route| {route.operation.lchop("AgentPagesSpec::"), route.agent_readable} }
    routes["Invoices::ShowPage"].should be_true
    routes["Invoices::Show"].should be_false
    routes["DashboardPage"].should be_false
  end

  it "answers an agent with markdown, a browser with HTML, and a program with JSON on a shared path" do
    client = AgentPagesSpec.client
    page = client.read(AgentPagesSpec::Invoices::ShowPage.href(invoice_id: 1_i64))
    page.status.should eq(HTTP::Status::OK)
    page.headers["Content-Type"].should eq("text/markdown; charset=utf-8; variant=GFM")
    page.headers["Vary"].should eq("Accept")
    page.body.should eq("# Invoice A-1\n\nBack to [all invoices](/agent_pages_spec/invoices.md)\n")
    page.trace.root.attributes["punch.surface"].should eq("markdown")
    page.trace.should have_span("render", "punch.view": "AgentPagesSpec::InvoiceView")

    html = client.visit("/agent_pages_spec/invoices/1")
    html.content_type.should eq("text/html")
    html.headers["Vary"].should eq("Accept")
    html.should have_element("nav svg")
    html.trace.root.attributes["punch.surface"].should eq("html")

    client.get("/agent_pages_spec/invoices/1").content_type.should eq("application/json")
    client.get("/agent_pages_spec/invoices/1", headers: HTTP::Headers{"Accept" => "application/json"}).content_type.should eq("application/json")
  end

  it "weighs markdown against HTML by q-values" do
    client = AgentPagesSpec.client
    {
      "text/markdown, text/html;q=0.5"   => "text/markdown",
      "text/html, text/markdown;q=0.9"   => "text/html",
      "text/*;q=0.5, text/markdown"      => "text/markdown",
      "application/json;q=0.1, text/*"   => "text/html",
      "text/plain"                       => "application/json",
      "text/markdown;q=0, text/html;q=0" => "application/json",
    }.each do |accept, served|
      client.get("/agent_pages_spec/invoices/1", headers: HTTP::Headers{"Accept" => accept}).content_type.should eq(served)
    end
  end

  it "answers a page-only path with HTML unless the client prefers markdown" do
    client = AgentPagesSpec.client
    html = client.get("/agent_pages_spec/invoices", headers: HTTP::Headers{"Accept" => "*/*"})
    html.content_type.should eq("text/html")
    html.headers["Vary"].should eq("Accept")
    markdown = client.read("/agent_pages_spec/invoices?page=2")
    markdown.content_type.should eq("text/markdown")
    markdown.body.should start_with("# Invoice page 2\n")
  end

  it "answers HTML for a page that did not opt in" do
    response = AgentPagesSpec.client.read("/agent_pages_spec/dashboard")
    response.content_type.should eq("text/html")
    response.headers["Vary"]?.should be_nil
  end

  it "renders problems as markdown for an agent" do
    client = AgentPagesSpec.client
    missing = client.read("/agent_pages_spec/invoices/2")
    missing.status.should eq(HTTP::Status::NOT_FOUND)
    missing.content_type.should eq("text/markdown")
    missing.body.should contain("# Not Found\n")
    missing.body.should contain("`not_found`")

    invalid = client.read("/agent_pages_spec/invoices", query: {page: "x"})
    invalid.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    invalid.content_type.should eq("text/markdown")
    invalid.body.should contain("- `page`: Must be a whole number. `expected_integer`")
  end

  it "answers an agent without a token with 401, never the sign-in page" do
    AuthSchema.with_spec_db do
      Punch::Pages.sign_in = AgentPagesSpec::Invoices::IndexPage.href
      client = AgentPagesSpec.client
      refused = client.read("/agent_pages_spec/invoices/drafts")
      refused.status.should eq(HTTP::Status::UNAUTHORIZED)
      refused.content_type.should eq("text/markdown")
      refused.headers["WWW-Authenticate"].should eq("Bearer")
      client.visit("/agent_pages_spec/invoices/drafts").status.should eq(HTTP::Status::SEE_OTHER)

      client.sign_in(1_i64)
      client.read("/agent_pages_spec/invoices/drafts").body.should start_with("# Invoice drafts of 1\n")
    ensure
      Punch::Pages.sign_in = nil
    end
  end

  it "answers the .md URL of an agent-readable page with markdown, without Accept" do
    client = AgentPagesSpec.client
    page = client.get("/agent_pages_spec/invoices/1.md")
    page.status.should eq(HTTP::Status::OK)
    page.content_type.should eq("text/markdown")
    page.headers["Vary"]?.should be_nil
    page.body.should eq("# Invoice A-1\n\nBack to [all invoices](/agent_pages_spec/invoices.md)\n")
    page.trace.root.attributes["punch.surface"].should eq("markdown")
    page.trace.root.attributes["http.route"].should eq("/agent_pages_spec/invoices/:invoice_id")

    client.get("/agent_pages_spec/invoices.md", query: {page: "2"}).body.should start_with("# Invoice page 2\n")
    head = client.head("/agent_pages_spec/invoices/1.md")
    {head.status, head.content_type}.should eq({HTTP::Status::OK, "text/markdown"})
    # The suffix decides, whatever the client accepts.
    client.get("/agent_pages_spec/invoices/1.md", headers: HTTP::Headers{"Accept" => "text/html"}).content_type.should eq("text/markdown")
  end

  it "answers the .md URL of anything else with 404, as markdown" do
    client = AgentPagesSpec.client
    {"/agent_pages_spec/dashboard.md", "/agent_pages_spec/invoices/2.md", "/agent_pages_spec/nothing.md", "/index.md"}.each do |path|
      missing = client.get(path)
      missing.status.should eq(HTTP::Status::NOT_FOUND)
      missing.content_type.should eq("text/markdown")
    end
    client.post("/agent_pages_spec/invoices/1.md", json: {} of String => String).status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "names the markdown in the HTML head of an agent-readable page" do
    client = AgentPagesSpec.client
    html = client.visit("/agent_pages_spec/invoices?page=2")
    html.should have_element(%(link[rel="alternate"][type="text/markdown"][href="/agent_pages_spec/invoices.md?page=2"]))
    client.visit("/agent_pages_spec/dashboard").should_not have_element(%(link[rel="alternate"]))
  end

  it "lists entry points in /llms.txt with how to sign in, act, and retry" do
    client = AgentPagesSpec.client
    llms = client.get("/llms.txt")
    llms.status.should eq(HTTP::Status::OK)
    llms.headers["Content-Type"].should eq("text/plain; charset=utf-8")
    llms.headers["Vary"]?.should be_nil
    body = llms.body
    body.should start_with("# Pages for agents\n\n")
    body.should contain("`Authorization: Bearer <token>`")
    body.should contain("`## Actions`")
    body.should contain("same idempotency key")
    body.should contain("Keys are kept for 24 hours.")
    body.should contain("`Retry-After`")
    body.should contain("\n## Pages\n\n")
    body.should contain("- [Agent pages spec invoices index page](/agent_pages_spec/invoices.md)\n")
    body.should_not contain("/agent_pages_spec/invoices/")
    body.should_not contain("/agent_pages_spec/dashboard")
    body.should_not contain("## Optional")
    llms.trace.root.attributes["punch.surface"].should eq("markdown")

    german = client.get("/llms.txt", headers: HTTP::Headers{"Accept-Language" => "de"})
    german.headers["Vary"].should eq("Accept-Language")
    german.body.should start_with("# Seiten für Agenten\n\n")
    german.body.should contain("\n## Seiten\n\n")
  end

  it "lists the OpenAPI document in /llms.txt when it is served" do
    client = Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db, openapi: %({"openapi": "3.2.0"})), openapi: nil)
    client.get("/llms.txt").body.should end_with("\n## Optional\n\n- [OpenAPI](/openapi.json): the JSON API's contract, for programs\n")
  end

  it "has no /llms.txt without entry points" do
    routes = Punch::Routing.routes.reject(&.entry)
    client = Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db, routes), openapi: nil)
    client.get("/llms.txt").status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "shows the surfaces of each route" do
    routes = Punch::Routing.routes.select(&.operation.starts_with?("AgentPagesSpec::")).to_h { |route| {route.operation.lchop("AgentPagesSpec::"), route} }
    routes["Invoices::ShowPage"].surfaces.should eq(["html", "markdown"])
    routes["Invoices::Show"].surfaces.should eq(["json"])
    routes["DashboardPage"].surfaces.should eq(["html"])
    routes["Invoices::IndexPage"].entry.should be_true
    routes["Invoices::ShowPage"].entry.should be_false
  end
end
