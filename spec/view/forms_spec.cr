require "../spec_helper"
require "../support/auth_schema"

module FormsSpec
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  enum Kind
    Plain
    CheckList
  end

  module Notes
    struct ID < Punch::TypedID
    end

    struct LineInput
      include Punch::Input

      getter text : Punch::NonEmptyString
      getter weight : Int32
    end

    @[Punch::Status(200)]
    struct Created
      include JSON::Serializable

      getter id : ID

      def initialize(@id : ID)
      end
    end

    @[Punch::Status(409)]
    struct Duplicate
      include JSON::Serializable

      def initialize
      end
    end

    @[Punch::Status(404)]
    struct NotFound
      include JSON::Serializable

      def initialize
      end
    end

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter title : Punch::NonEmptyString
        getter email : Punch::Email?
        getter kind : Kind
        getter? pinned : Bool = false
        getter public : Bool?
        getter weight : Int32 = 1
        getter body : String?
        getter lines : Array(LineInput)?
      end

      def call(input : Input, db : Punch::Writer) : Created | Duplicate
        return Duplicate.new if input.title.value == "taken"

        Created.new(ID.parse(42).as(ID))
      end
    end

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Update < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : ID

        getter title : Punch::NonEmptyString?
        getter weight : Int32?
      end

      def call(input : Input, db : Punch::Writer) : Created | NotFound
        input.note_id.value > 100 ? NotFound.new : Created.new(input.note_id)
      end
    end

    @[Punch::Public]
    struct Destroy < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : ID
      end

      def call(input : Input, db : Punch::Writer, actor : Actor) : Nil
      end
    end

    # Fails for note 2, which is archived already.
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Archive < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : ID
      end

      def call(input : Input, db : Punch::Writer) : Created | Duplicate
        input.note_id.value == 2 ? Duplicate.new : Created.new(input.note_id)
      end
    end

    # No page holds its form: JSON only.
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Ping < Punch::Command
      struct Input
        include Punch::Input

        getter text : String?
      end

      def call(input : Input, db : Punch::Writer) : Nil
      end
    end

    struct NoteForm
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.document("New note") do
          v.form(Create.action, values: {kind: Kind::CheckList, weight: 3, lines: [{text: Punch::NonEmptyString.parse("first").as(Punch::NonEmptyString), weight: 1}]}, class: "note") do |form|
            form.field :title, hint: "Shown in lists"
            form.field :email
            form.field :kind
            form.field :pinned
            form.field :public
            form.field :weight
            form.field :body, as: :textarea
            v.fieldset do
              v.legend "Lines"
              form.each(:lines, LineInput, blank: 1) do |line, index|
                v.div(class: "line", data: {index: index}) do
                  line.field :text
                  line.field :weight
                end
              end
            end
            form.submit "Create"
          end
        end
      end
    end

    @[Punch::Public]
    struct CreatePage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader) : NoteForm
        NoteForm.new
      end

      def self.redirect(result : Created) : Punch::Href
        ShowPage.href(note_id: result.id)
      end
    end

    struct EditForm
      include Punch::Component

      def initialize(@id : ID)
      end

      def view(v : Punch::View) : Nil
        v.document("Edit") do
          v.form(Update.action(note_id: @id), values: {title: Punch::NonEmptyString.parse("Old <title>").as(Punch::NonEmptyString), weight: 5}) do |form|
            form.field :title
            form.field :weight
            form.submit "Save"
          end
          v.form(Update.action(note_id: @id), turbo_method: true, class: "turbo") { |form| form.submit "Save" }
        end
      end
    end

    @[Punch::Public]
    struct UpdatePage < Punch::Page
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : ID
      end

      def call(input : Input, db : Punch::Reader) : EditForm
        EditForm.new(input.note_id)
      end

      def self.redirect(result : Created) : Punch::Href
        ShowPage.href(note_id: result.id)
      end
    end

    struct Detail
      include Punch::Component

      def initialize(@id : ID)
      end

      def view(v : Punch::View) : Nil
        v.document("Note") do
          v.frame(@id) do
            v.h1 "Note #{@id}"
            v.form(Destroy.action(note_id: @id)) { |form| form.submit "Delete", class: "danger" }
          end
          v.frame(@id, "lines", src: IndexPage.href, loading: "lazy") { }
        end
      end
    end

    @[Punch::Forms(Destroy)]
    @[Punch::Public]
    struct ShowPage < Punch::Page
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : ID
      end

      def call(input : Input, db : Punch::Reader) : Detail
        Detail.new(input.note_id)
      end

      def self.redirect(result : Nil) : Punch::Href
        IndexPage.href
      end
    end

    # What narrows a note's lines, as a generated query's Filter would.
    struct SearchFilter
      include Punch::Input

      getter kind : Kind?
      getter title : String?
      getter? pinned : Bool = false

      def initialize(*, @kind : Kind? = nil, @title : String? = nil, @pinned : Bool = false)
      end
    end

    struct SearchView
      include Punch::Component

      def initialize(@input : SearchPage::Input)
      end

      def view(v : Punch::View) : Nil
        v.document("Search") do
          v.filter_form(SearchPage, @input, class: "search") do |form|
            form.fields(:filter, SearchFilter) do |filter|
              filter.field :kind
              filter.field :title
              filter.field :pinned
            end
            form.field :limit, as: :hidden
            form.submit "Filter"
          end
          v.a "Next", href: SearchPage.href(note_id: @input.note_id, filter: @input.filter, after: 3), rel: "next"
        end
      end
    end

    @[Punch::Public]
    struct SearchPage < Punch::Page
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : ID

        getter filter : SearchFilter = SearchFilter.new
        getter after : Int32?
        getter limit : Int32 = 20
      end

      def call(input : Input, db : Punch::Reader) : SearchView
        SearchView.new(input)
      end
    end

    # The same list as JSON, on the page's path.
    @[Punch::Public]
    struct Search < Punch::Query
      alias Input = SearchPage::Input

      def call(input : Input, db : Punch::Reader) : Created
        Created.new(input.note_id)
      end
    end

    struct List
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.document("Notes") do
          v.ul do
            [1, 2].each do |number|
              id = ID.parse(number).as(ID)
              v.li { v.form(Archive.action(note_id: id)) { |form| form.submit "Archive #{number}" } }
            end
          end
        end
      end
    end

    @[Punch::Forms(Archive)]
    @[Punch::Public]
    struct IndexPage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader) : List
        List.new
      end
    end
  end

  # A form used after its block ended.
  struct Escaped
    include Punch::Component

    def view(v : Punch::View) : Nil
      kept = nil
      v.form(Notes::Archive.action(note_id: Notes::ID.parse(1).as(Notes::ID))) { |form| kept = form }
      kept.try(&.submit("Late"))
    end
  end

  struct Nested
    include Punch::Component

    def view(v : Punch::View) : Nil
      v.form(Notes::Archive.action(note_id: Notes::ID.parse(1).as(Notes::ID))) do
        v.div { v.form(Notes::Create.action) { } }
      end
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end
end

private def note(id : Int32) : FormsSpec::Notes::ID
  FormsSpec::Notes::ID.parse(id).as(FormsSpec::Notes::ID)
end

describe "forms bound to Commands" do
  it "writes a form from the Command's input: names, labels, controls by type, values" do
    page = FormsSpec.client.visit(FormsSpec::Notes::CreatePage.href)
    page.status.should eq(HTTP::Status::OK)
    page.should have_element("form#forms-spec-notes-post.note[method=post][action='/forms_spec/notes']")
    page.should have_element("label[for=forms-spec-notes-post-title]", text: "Title")
    page.should have_element("input#forms-spec-notes-post-title[name=title][type=text][required][aria-describedby=forms-spec-notes-post-title-hint]")
    page.should have_element("p#forms-spec-notes-post-title-hint.field-hint", text: "Shown in lists")
    # International addresses: text with the email keyboard, not type=email.
    page.should have_element("input[name=email][type=text][inputmode=email][maxlength='254']")
    page.should_not have_element("input[name=email][required]")
    page.should have_element("select[name=kind][required] option", count: 2)
    page.should have_element("select[name=kind] option[value=check_list][selected]", text: "Check list")
    page.should have_element("div.field.field-checkbox input[name=pinned][type=checkbox][value=true]")
    page.should_not have_element("input[name=pinned][checked]")
    page.should have_element("select[name=public] option", count: 3)
    page.should have_element("input[name=weight][type=number][step='1'][value='3']")
    page.should have_element("textarea[name=body]", text: "")
    page.should have_element("div.line input[name='lines[0][text]'][value=first]")
    page.should have_element("div.line input[name='lines[1][text]']")
    page.should_not have_element("input[name='lines[2][text]']")
    page.should have_element("fieldset > legend", text: "Lines")
    page.should have_element("button[type=submit]", text: "Create")
    page.should_not have_element(".form-errors")
  end

  it "sends other methods through ?_method and fills given values, escaped" do
    page = FormsSpec.client.visit(FormsSpec::Notes::UpdatePage.href(note_id: note(7)))
    page.should have_element("form[method=post][action='/forms_spec/notes/7?_method=PATCH']")
    page.should have_element("form.turbo[method=patch][action='/forms_spec/notes/7']")
    page.should have_element("input[name=title][value='Old <title>']")
    page.body.should contain(%(value="Old &lt;title&gt;"))
    page.should_not have_element("input[name=title][required]")
  end

  it "answers an accepted form with 303 to the page's redirect" do
    client = FormsSpec.client
    response = client.submit(FormsSpec::Notes::Create.action, {title: Punch::NonEmptyString.parse("Hi").as(Punch::NonEmptyString), kind: FormsSpec::Kind::Plain})
    response.should redirect_to(FormsSpec::Notes::ShowPage.href(note_id: note(42)))
    response.body.should be_empty
    response.trace.root.attributes["punch.surface"].should eq("html")
    client.submit(FormsSpec::Notes::Update.action(note_id: note(7)), {weight: 2}).should redirect_to("/forms_spec/notes/7")
  end

  it "redirects to the holding page by default, and per result type" do
    AuthSchema.with_spec_db do
      client = FormsSpec.client
      client.submit(FormsSpec::Notes::Archive.action(note_id: note(1))).should redirect_to(FormsSpec::Notes::IndexPage.href)
      client.sign_in(1_i64)
      client.submit(FormsSpec::Notes::Destroy.action(note_id: note(3))).should redirect_to(FormsSpec::Notes::IndexPage.href)
    end
  end

  it "shows a refused form again with 422, what was sent, and every error" do
    response = FormsSpec.client.submit(FormsSpec::Notes::Create.action, form: {
      "title" => "Mine", "email" => "not an address", "kind" => "other", "weight" => "x", "pinned" => "true",
      "body" => "\nstarts with a newline",
      "lines[0][text]" => "a", "lines[0][weight]" => "1",
      "lines[1][text]" => "", "lines[1][weight]" => "",
      "lines[2][text]" => "c", "lines[2][weight]" => "heavy",
    })
    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.content_type.should eq("text/html")
    response.should have_field_error("email", "invalid_email")
    response.should have_field_error("kind", "invalid_choice")
    response.should have_field_error("weight", "expected_integer")
    response.should have_field_error("lines[2][weight]", "expected_integer")
    response.should_not have_field_error("title")
    response.should_not have_field_error("lines[0][weight]")
    response.should have_element(".form-errors[role=alert] li", count: 4)
    response.should have_element(".form-errors li a[href='#forms-spec-notes-post-lines-2-weight']", text: "Weight")
    response.should have_element("div.field.field-invalid input[name=email][aria-invalid=true]")
    response.should have_element("input[name=title][value=Mine]")
    response.should have_element("input[name=email][value='not an address']")
    response.should have_element("input[name=pinned][checked]")
    response.should have_element("input[name='lines[2][weight]'][value=heavy]")
    # The blank row stays, and one more is added.
    response.should have_element("input[name='lines[3][text]']")
    response.should have_element("textarea[name=body]", text: "starts with a newline")
    response.body.should contain("<textarea name=\"body\" id=\"forms-spec-notes-post-body\">\n\nstarts")
    response.trace.root.attributes["punch.outcome"].should eq("invalid_input")
  end

  it "shows a failure result as the form's error, with its status" do
    response = FormsSpec.client.submit(FormsSpec::Notes::Create.action, form: {"title" => "taken", "kind" => "plain"})
    response.status.should eq(HTTP::Status::CONFLICT)
    response.should have_element(".form-errors li[data-code=duplicate]", text: "duplicate")
    response.should have_element("input[name=title][value=taken]")
    response.trace.root.attributes["punch.outcome"].should eq("duplicate")
  end

  it "shows the errors only on the form that was sent" do
    response = FormsSpec.client.submit(FormsSpec::Notes::Archive.action(note_id: note(2)))
    response.status.should eq(HTTP::Status::CONFLICT)
    response.should have_element("form", count: 2)
    response.should have_element("form[action='/forms_spec/notes/2/archive'] .form-errors li[data-code=duplicate]")
    response.should_not have_element("form[action='/forms_spec/notes/1/archive'] .form-errors")
  end

  it "answers 404 when the path does not parse and the holding page cannot be shown" do
    response = FormsSpec.client.submit(FormsSpec::Notes::Update.action(note_id: note(7)), form: {"weight" => "1"})
    response.status.should eq(HTTP::Status::SEE_OTHER)
    response = FormsSpec.client.request("POST", "/forms_spec/notes/abc?_method=PATCH", body: "weight=1",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Accept" => Punch::Spec::BROWSER_ACCEPT})
    response.status.should eq(HTTP::Status::NOT_FOUND)
    response.content_type.should eq("text/html")
  end

  it "keeps JSON for programs, and takes ?_method only with a form body" do
    client = FormsSpec.client
    json = client.post("/forms_spec/notes", json: {title: "Hi", kind: "plain"})
    json.status.should eq(HTTP::Status::OK)
    json.json["id"].should eq(42)
    client.post("/forms_spec/notes", json: {title: ""}).content_type.should eq("application/problem+json")
    client.post("/forms_spec/notes/7?_method=PATCH", json: {weight: 1}).status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
    client.request("PATCH", "/forms_spec/notes/7", json: {weight: 1}).status.should eq(HTTP::Status::OK)
    client.request("POST", "/forms_spec/notes/7?_method=GET", body: "weight=1",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}).status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
  end

  it "takes the form Turbo sends with the method itself (method=\"patch\")" do
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Accept" => Punch::Spec::BROWSER_ACCEPT, "Sec-Fetch-Site" => "same-origin"}
    client = FormsSpec.client
    client.request("PATCH", "/forms_spec/notes/7", body: "weight=2", headers: headers).should redirect_to("/forms_spec/notes/7")
    refused = client.request("PATCH", "/forms_spec/notes/7", body: "weight=x", headers: headers)
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.should have_field_error("weight", "expected_integer")
    # Like any Command, refused from another site.
    client.request("PATCH", "/forms_spec/notes/7", body: "weight=2",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Sec-Fetch-Site" => "cross-site"}).status.should eq(HTTP::Status::FORBIDDEN)
  end

  it "refuses a form body for a Command no page holds" do
    response = FormsSpec.client.request("POST", "/forms_spec/notes/ping", body: "text=x",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    response.status.should eq(HTTP::Status::UNSUPPORTED_MEDIA_TYPE)
  end

  it "refuses a form from another site" do
    response = FormsSpec.client.submit(FormsSpec::Notes::Archive.action(note_id: note(1)),
      headers: HTTP::Headers{"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"})
    response.status.should eq(HTTP::Status::FORBIDDEN)
    response.content_type.should eq("text/html")
  end

  it "asks for sign-in with a 401 page" do
    AuthSchema.with_spec_db do
      response = FormsSpec.client.submit(FormsSpec::Notes::Destroy.action(note_id: note(3)))
      response.status.should eq(HTTP::Status::UNAUTHORIZED)
      response.content_type.should eq("text/html")
      response.headers["WWW-Authenticate"]?.should_not be_nil
    end
  end

  it "sends a browser to the app's sign-in page when it has one" do
    AuthSchema.with_spec_db do
      Punch::Pages.sign_in = FormsSpec::Notes::IndexPage.href
      response = FormsSpec.client.submit(FormsSpec::Notes::Destroy.action(note_id: note(3)))
      response.status.should eq(HTTP::Status::SEE_OTHER)
      response.headers["Location"].should eq("/forms_spec/notes")
      response.headers["WWW-Authenticate"]?.should be_nil
    ensure
      Punch::Pages.sign_in = nil
    end
  end

  it "lists the page that holds each Command's form in the route table" do
    routes = Punch::Routing.routes.select(&.operation.starts_with?("FormsSpec::"))
    routes.find!(&.operation.==("FormsSpec::Notes::Create")).form_page.should eq("FormsSpec::Notes::CreatePage")
    routes.find!(&.operation.==("FormsSpec::Notes::Destroy")).form_page.should eq("FormsSpec::Notes::ShowPage")
    routes.find!(&.operation.==("FormsSpec::Notes::Archive")).form_page.should eq("FormsSpec::Notes::IndexPage")
    routes.find!(&.operation.==("FormsSpec::Notes::Ping")).form_page.should be_nil
  end

  it "writes a GET form to a page, showing the input it was given, without its cursor" do
    href = FormsSpec::Notes::SearchPage.href(note_id: note(7), filter: FormsSpec::Notes::SearchFilter.new(kind: :check_list, title: "a<b"), after: 5, limit: 10)
    href.to_s.should eq("/forms_spec/notes/7/search?filter%5Bkind%5D=check_list&filter%5Btitle%5D=a%3Cb&after=5&limit=10")
    page = FormsSpec.client.visit(href)
    page.status.should eq(HTTP::Status::OK)
    page.should have_element("form.search[method=get][action='/forms_spec/notes/7/search']")
    page.should have_element("select[name='filter[kind]'] option", count: 3)
    page.should have_element("select[name='filter[kind]'] option[value=check_list][selected]")
    page.should have_element("input[name='filter[title]'][type=text][value='a<b']")
    page.should_not have_element("input[name='filter[title]'][required]")
    page.should have_element("input[name='filter[pinned]'][type=checkbox]")
    page.should_not have_element("input[name='filter[pinned]'][checked]")
    page.should have_element("input[name=limit][type=hidden][value='10']")
    page.should_not have_element("[name=after]")
    page.should_not have_element("[name=_csrf], [name=_method]")
    # A link carries the filter in brackets too, leaving out what holds its default.
    page.should have_element("a[rel=next][href='/forms_spec/notes/7/search?filter%5Bkind%5D=check_list&filter%5Btitle%5D=a%3Cb&after=3']")
  end

  it "reads what a GET form sends back into the page's input" do
    page = FormsSpec.client.visit(Punch::Href.new("/forms_spec/notes/7/search?filter[kind]=plain&filter[title]=&filter[pinned]=true&limit=10", nil))
    page.should have_element("select[name='filter[kind]'] option[value=plain][selected]")
    page.should have_element("input[name='filter[pinned]'][checked]")
    FormsSpec.client.visit(Punch::Href.new("/forms_spec/notes/7/search?filter[kind]=nope", nil)).status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
  end

  it "documents a nested input as one deepObject query parameter, and answers JSON from it" do
    registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
    route = Punch::Routing.routes.find!(&.operation.== "FormsSpec::Notes::Search")
    entry = Punch::OpenAPI.operation(FormsSpec::Notes::Search, route, registry)
    filter = entry["parameters"].as_a.find! { |parameter| parameter["name"] == "filter" }
    filter.should eq(JSON.parse(%({"name": "filter", "in": "query", "schema": {"$ref": "#/components/schemas/FormsSpec.Notes.SearchFilter"}, "style": "deepObject", "explode": true})))
    entry["parameters"].as_a.find! { |parameter| parameter["name"] == "limit" }["style"]?.should be_nil
    response = FormsSpec.client.get("/forms_spec/notes/7/search?filter[kind]=nope")
    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.body.should contain(%("filter","kind"]))
  end

  it "writes Turbo Frames with DOM IDs from typed IDs" do
    page = FormsSpec.client.visit(FormsSpec::Notes::ShowPage.href(note_id: note(9)))
    page.should have_element("turbo-frame#notes_9 h1", text: "Note 9")
    page.should have_element("turbo-frame#lines_notes_9[src='/forms_spec/notes'][loading=lazy]")
    page.should have_element("turbo-frame#notes_9 form[action='/forms_spec/notes/9?_method=DELETE'] button.danger", text: "Delete")
    Punch.dom_id(note(9)).should eq("notes_9")
  end

  it "raises on forms inside forms and controls outside them" do
    expect_raises(Punch::View::NestingError, "<form> cannot hold another <form>") { Punch::Spec.render(FormsSpec::Nested.new) }
    expect_raises(Punch::View::NestingError, "<button> belongs inside a form") { Punch::Spec.render(FormsSpec::Escaped.new) }
  end
end
