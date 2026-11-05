require "../spec_helper"
require "../support/auth_schema"

module PagesSpec
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  enum Status
    Draft
    Sent
  end

  @[Punch::Status(404)]
  struct NotFound
    include JSON::Serializable

    def initialize
    end
  end

  # A component that is also a failure: a custom 410 page.
  @[Punch::Status(410)]
  struct Gone
    include Punch::Component

    def view(v : Punch::View) : Nil
      v.document("Gone") { v.h1 "This note was deleted" }
    end
  end

  @[Punch::Status(200)]
  struct Note
    include JSON::Serializable

    getter id : Int64
    getter title : String

    def initialize(@id, @title)
    end
  end

  @[Punch::Status(200)]
  struct NoteView
    include Punch::Component

    def initialize(@note : Note, @links : Array(Punch::Href) = [] of Punch::Href)
    end

    def view(v : Punch::View) : Nil
      v.document("Note #{@note.id}") do
        v.h1 @note.title
        v.ul { @links.each { |href| v.li { v.a href.url, href: href } } }
      end
    end
  end

  module Notes
    @[Punch::Public]
    struct Show < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : Int64
      end

      def call(input : Input, db : Punch::Reader) : Note | NotFound
        input.note_id == 1 ? Note.new(1, "First <note>") : NotFound.new
      end
    end

    @[Punch::Public]
    struct ShowPage < Punch::Page
      alias Input = Show::Input

      def call(input : Input, db : Punch::Reader) : NoteView | NotFound | Gone
        return Gone.new if input.note_id == 410

        case note = Show.new.call(input, db)
        in NotFound then note
        in Note     then NoteView.new(note)
        end
      end
    end

    @[Punch::Public]
    struct IndexPage < Punch::Page
      struct Input
        include Punch::Input

        getter page : Int32 = 1
        getter status : Status?
        getter tags : Array(String) = [] of String
        getter since : Time?
      end

      def call(input : Input, db : Punch::Reader) : NoteView
        NoteView.new(Note.new(input.page.to_i64, "#{input.status} #{input.tags.join("|")} #{input.since}"), [
          IndexPage.href(page: input.page + 1),
          ShowPage.href(note_id: 1_i64),
          EditPage.href(note_id: 7_i64),
          CreatePage.href,
          IndexPage.href(page: 2, status: Status::Sent, tags: ["a b", "c&d"], since: Time.utc(2026, 1, 2, 3, 4, 5)),
          IndexPage.href(status: nil),
        ])
      end
    end

    @[Punch::Public]
    struct CreatePage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader) : NoteView
        NoteView.new(Note.new(0, "new"))
      end
    end

    @[Punch::Public]
    struct UpdatePage < Punch::Page
      alias Input = Show::Input

      def call(input : Input, db : Punch::Reader) : NoteView
        NoteView.new(Note.new(input.note_id, "edit"))
      end
    end

    # Named like a Command's form page: GET /pages_spec/notes/:note_id/archive.
    @[Punch::Public]
    struct ArchivePage < Punch::Page
      alias Input = Show::Input

      def call(input : Input, db : Punch::Reader, actor : Actor) : NoteView
        NoteView.new(Note.new(input.note_id, "archive as #{actor.principal.user_id}"))
      end
    end

    alias EditPage = UpdatePage

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Archive < Punch::Command
      alias Input = Show::Input

      def call(input : Input, db : Punch::Writer) : Nil
      end
    end
  end

  @[Punch::Route("GET", "/pages-spec")]
  @[Punch::Public]
  struct HomePage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, actor : Actor?) : NoteView
      NoteView.new(Note.new(0, actor ? "signed in" : "anonymous"))
    end
  end

  BROWSER = HTTP::Headers{"Accept" => Punch::Spec::BROWSER_ACCEPT}

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end
end

describe Punch::Page do
  it "derives routes from the name without its suffix" do
    routes = Punch::Routing.routes.select(&.operation.starts_with?("PagesSpec::"))
      .map { |route| {route.method, route.template, route.kind.surface, route.operation.lchop("PagesSpec::")} }
    routes.should contain({"GET", "/pages_spec/notes/:note_id", "html", "Notes::ShowPage"})
    routes.should contain({"GET", "/pages_spec/notes/:note_id", "json", "Notes::Show"})
    routes.should contain({"GET", "/pages_spec/notes", "html", "Notes::IndexPage"})
    routes.should contain({"GET", "/pages_spec/notes/new", "html", "Notes::CreatePage"})
    routes.should contain({"GET", "/pages_spec/notes/:note_id/edit", "html", "Notes::UpdatePage"})
    routes.should contain({"GET", "/pages_spec/notes/:note_id/archive", "html", "Notes::ArchivePage"})
    routes.should contain({"POST", "/pages_spec/notes/:note_id/archive", "json", "Notes::Archive"})
    routes.should contain({"GET", "/pages-spec", "html", "HomePage"})
  end

  it "builds typed links, with query parameters as the input parses them" do
    PagesSpec::Notes::ShowPage.href(note_id: 42_i64).url.should eq("/pages_spec/notes/42")
    PagesSpec::Notes::ShowPage.href(note_id: 42_i64).page.should eq("PagesSpec::Notes::ShowPage")
    PagesSpec::Notes::IndexPage.href.url.should eq("/pages_spec/notes")
    PagesSpec::Notes::IndexPage.href(status: nil, since: nil).url.should eq("/pages_spec/notes")
    href = PagesSpec::Notes::IndexPage.href(page: 2, status: PagesSpec::Status::Sent, tags: ["a b", "c&d"], since: Time.utc(2026, 1, 2, 3, 4, 5))
    href.url.should eq("/pages_spec/notes?page=2&status=sent&tags=a+b&tags=c%26d&since=2026-01-02T03%3A04%3A05Z")
    query = URI.parse(href.url).query_params

    case input = PagesSpec::Notes::IndexPage::Input.from_query(query)
    in Punch::Rejection then fail "the link's query does not parse: #{input.errors}"
    in PagesSpec::Notes::IndexPage::Input
      input.page.should eq(2)
      input.status.should eq(PagesSpec::Status::Sent)
      input.tags.should eq(["a b", "c&d"])
      input.since.should eq(Time.utc(2026, 1, 2, 3, 4, 5))
    end
  end

  it "answers a browser with the page and a program with JSON on a shared path" do
    client = PagesSpec.client
    page = client.visit(PagesSpec::Notes::ShowPage.href(note_id: 1_i64))
    page.status.should eq(HTTP::Status::OK)
    page.content_type.should eq("text/html")
    page.headers["Vary"].should eq("Accept")
    page.should have_element("h1", text: "First <note>")
    page.trace.root.attributes["punch.surface"].should eq("html")
    page.trace.root.attributes["punch.operation"].should eq("PagesSpec::Notes::ShowPage")
    page.trace.should have_span("render", "punch.view": "PagesSpec::NoteView")

    json = client.get("/pages_spec/notes/1")
    json.content_type.should eq("application/json")
    json.headers["Vary"].should eq("Accept")
    json.json["title"].should eq("First <note>")
    json.trace.root.attributes["punch.surface"].should eq("json")

    client.get("/pages_spec/notes/1", headers: HTTP::Headers{"Accept" => "text/html"}).content_type.should eq("text/html")
    client.get("/pages_spec/notes/1", headers: HTTP::Headers{"Accept" => "*/*"}).content_type.should eq("application/json")
  end

  it "answers a page-only path with HTML whatever the client accepts" do
    response = PagesSpec.client.get("/pages_spec/notes", headers: HTTP::Headers{"Accept" => "application/json"})
    response.content_type.should eq("text/html")
    response.headers["Vary"]?.should be_nil
    response.should have_element("a[href='/pages_spec/notes?page=2']")
    response.should have_element("a[href='/pages_spec/notes/new']")
    response.should have_element("a[href='/pages_spec/notes/7/edit']")
  end

  it "says a routing problem varies by Accept, since it chooses page or Problem Details" do
    PagesSpec.client.get("/pages_spec/no_such_path").headers["Vary"].should eq("Accept")
  end

  it "renders failures as problem pages, and failure components with their status" do
    client = PagesSpec.client
    missing = client.visit("/pages_spec/notes/2")
    missing.status.should eq(HTTP::Status::NOT_FOUND)
    missing.should have_element("main.punch-problem h1", text: "Not Found")
    missing.should have_element("code", text: "not_found")
    missing.should have_element("code", text: missing.headers["X-Request-ID"])
    missing.trace.root.attributes["punch.outcome"].should eq("not_found")

    gone = client.visit("/pages_spec/notes/410")
    gone.status.should eq(HTTP::Status::GONE)
    gone.should have_element("h1", text: "This note was deleted")
  end

  it "answers 404 for a path parameter that does not parse, 422 for a query parameter" do
    client = PagesSpec.client
    client.visit("/pages_spec/notes/abc").status.should eq(HTTP::Status::NOT_FOUND)
    invalid = client.visit("/pages_spec/notes", query: {page: "x", status: "lost"})
    invalid.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    invalid.should have_element("li", text: "page: Must be a whole number. expected_integer")
    invalid.should have_element("li", text: "status: Is not one of the choices. invalid_choice")
  end

  it "answers routing errors with a page when the client prefers HTML" do
    client = PagesSpec.client
    page = client.visit("/pages_spec/nowhere")
    page.status.should eq(HTTP::Status::NOT_FOUND)
    page.content_type.should eq("text/html")
    client.get("/pages_spec/nowhere").content_type.should eq("application/problem+json")

    not_allowed = client.request("DELETE", "/pages_spec/notes/1", headers: PagesSpec::BROWSER)
    not_allowed.status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
    not_allowed.headers["Allow"].should eq("GET, HEAD")
    not_allowed.content_type.should eq("text/html")
    client.request("PUT", "/pages_spec/notes/1/archive", headers: PagesSpec::BROWSER).headers["Allow"].should eq("GET, HEAD, POST")
  end

  it "answers HEAD from the page" do
    response = PagesSpec.client.head("/pages_spec/notes", headers: PagesSpec::BROWSER)
    response.status.should eq(HTTP::Status::OK)
    response.content_type.should eq("text/html")
  end

  it "asks for sign-in with a 401 page and serves signed-in actors" do
    AuthSchema.with_spec_db do
      client = PagesSpec.client
      refused = client.visit("/pages_spec/notes/5/archive")
      refused.status.should eq(HTTP::Status::UNAUTHORIZED)
      refused.headers["WWW-Authenticate"].should eq("Bearer")
      refused.should have_element("code", text: "unauthenticated")

      client.visit("/pages-spec").should have_element("h1", text: "anonymous")
      client.sign_in(1_i64)
      client.visit("/pages_spec/notes/5/archive").should have_element("h1", text: "archive as 1")
      client.visit("/pages-spec").should have_element("h1", text: "signed in")
    end
  end

  it "sends a browser to the sign-in page instead, when the app has one" do
    AuthSchema.with_spec_db do
      Punch::Pages.sign_in = PagesSpec::Notes::CreatePage.href
      response = PagesSpec.client.visit("/pages_spec/notes/5/archive")
      response.status.should eq(HTTP::Status::SEE_OTHER)
      response.headers["Location"].should eq("/pages_spec/notes/new")
      response.headers["WWW-Authenticate"]?.should be_nil

      # A bearer token was meant to authenticate: no detour through a form.
      bearer = PagesSpec.client.request("GET", "/pages_spec/notes/5/archive",
        headers: HTTP::Headers{"Accept" => "text/html", "Authorization" => "Bearer nope"})
      bearer.status.should eq(HTTP::Status::UNAUTHORIZED)
      bearer.headers["WWW-Authenticate"].should eq(%(Bearer error="invalid_token"))
    ensure
      Punch::Pages.sign_in = nil
    end
  end
end
