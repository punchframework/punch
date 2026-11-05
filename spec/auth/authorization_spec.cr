require "../spec_helper"
require "../support/auth_schema"

module AuthorizationSpec
  struct UserID < Punch::TypedID
  end

  struct NoteID < Punch::TypedID
  end

  struct Actor
    include Punch::Auth::Actor

    getter id : UserID

    def initialize(@id)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal.user_id(UserID))
    end
  end

  SQL = <<-SQL
    CREATE TABLE notes (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, body TEXT NOT NULL, locked INTEGER NOT NULL DEFAULT 0) STRICT;
    INSERT INTO notes (id, owner_id, body, locked) VALUES (1, 1, 'Ada''s', 0), (2, 2, 'Grace''s', 0), (3, 1, 'Ada''s locked', 1);
    SQL

  # Only a note's owner may see or change it; others do not learn it
  # exists. A locked note is visible to its owner but not editable.
  struct Owner
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, *, note_id : NoteID) : Punch::Policy::Decision
      owner = db.query_one?("SELECT owner_id FROM notes WHERE id = ?", note_id.value, &.read(Int64)) || return allow
      owner == actor.id.value ? allow : not_found
    end
  end

  struct Editor
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, *, note_id : NoteID) : Punch::Policy::Decision
      case Owner.check(actor, db, note_id: note_id)
      when .allow?
        locked = db.query_one?("SELECT locked FROM notes WHERE id = ?", note_id.value, &.read(Int64))
        locked == 1 ? forbid : allow
      else
        not_found
      end
    end
  end

  # Anyone may ask; only a signed-in user hears the secret.
  struct Visitors
    include Punch::Policy

    def self.check(actor : Actor?, db : Punch::Reader | Punch::Writer) : Punch::Policy::Decision
      allow
    end
  end

  @[Punch::Status(200)]
  struct Note
    include JSON::Serializable

    getter body : String

    def initialize(@body)
    end
  end

  @[Punch::Status(404)]
  struct Missing
    include JSON::Serializable

    def initialize
    end
  end

  module Notes
    @[Punch::Authorize(Owner)]
    struct Show < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : NoteID
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : Note | Missing
        body = db.query_one?("SELECT body FROM notes WHERE id = ?", input.note_id.value, &.read(String))
        body ? Note.new(body) : Missing.new
      end
    end

    @[Punch::Authorize(Editor)]
    struct Update < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : NoteID

        getter body : String
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Update)) : Note
        db.exec("UPDATE notes SET body = ? WHERE id = ?", input.body, input.note_id.value)
        Note.new(input.body)
      end
    end

    @[Punch::Authorize(Punch::SignedIn)]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter body : String
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Create)) : Note
        Note.new(input.body)
      end
    end

    # One note with its edit form, and links around it.
    @[Punch::Status(200)]
    struct NoteView
      include Punch::Component

      def initialize(@id : NoteID, @note : Note)
      end

      def view(v : Punch::View) : Nil
        v.main do
          v.p @note.body
          v.form(Update.action(note_id: @id)) { |form| form.field :body; form.submit "Save" }
          v.ul do
            {1, 2, 3}.each { |id| v.li { v.a "Note #{id}", href: ShowPage.href(note_id: NoteID.parse(id).as(NoteID)) } }
            v.li { v.a "Front", href: FrontPage.href }
            v.li { v.a "Mine", href: MinePage.href }
          end
        end
      end
    end

    @[Punch::Authorize(Owner)]
    @[Punch::Forms(Update)]
    struct ShowPage < Punch::Page
      alias Input = Show::Input

      def call(input : Input, db : Punch::Reader, actor : Actor) : NoteView | Missing
        case note = Show.new.call(input, db, actor)
        in Missing then note
        in Note    then NoteView.new(input.note_id, note)
        end
      end
    end

    struct Links
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.main do
          v.a "Mine", href: MinePage.href
          v.a "Front", href: FrontPage.href
          v.form(Create.action) { |form| form.field :body; form.submit "Add" }
        end
      end
    end

    @[Punch::Public]
    @[Punch::Forms(Create)]
    struct FrontPage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, actor : Actor?) : Links
        Links.new
      end
    end

    @[Punch::Authorize(Punch::SignedIn)]
    struct MinePage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : Links
        Links.new
      end
    end
  end

  @[Punch::Authorize(Visitors)]
  struct Secret < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, actor : Actor?, grant : Punch::Grant(Secret)) : Note
      Note.new(actor ? "the secret" : "nothing")
    end
  end

  def self.with_db(&)
    AuthSchema.with_spec_db do
      Punch::Spec.db.write { |db| SQL.each_line { |statement| db.exec(statement) } }
      yield
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end

  def self.ada : Punch::Spec::Client
    client.sign_in(UserID.parse(1).as(UserID))
  end

  def self.note(id : Int32) : NoteID
    NoteID.parse(id).as(NoteID)
  end

  def self.body(id : Int32) : String?
    Punch::Spec.db.read(&.query_one?("SELECT body FROM notes WHERE id = ?", id, &.read(String)))
  end
end

describe "Authorization" do
  it "runs the policy and records the decision on the wide event" do
    AuthorizationSpec.with_db do
      response = AuthorizationSpec.ada.get(AuthorizationSpec::Notes::Show.path(note_id: AuthorizationSpec.note(1)))
      response.status.should eq(HTTP::Status::OK)
      response.json["body"].should eq("Ada's")
      response.trace.root["punch.policy"].should eq("AuthorizationSpec::Owner")
      response.trace.root["punch.authz"].should eq("allow")
    end
  end

  it "answers 404 where the policy hides the resource, like a missing one" do
    AuthorizationSpec.with_db do
      hidden = AuthorizationSpec.ada.get(AuthorizationSpec::Notes::Show.path(note_id: AuthorizationSpec.note(2)))
      hidden.status.should eq(HTTP::Status::NOT_FOUND)
      hidden.json["code"].should eq("not_found")
      hidden.trace.root["punch.authz"].should eq("not_found")
      missing = AuthorizationSpec.ada.get(AuthorizationSpec::Notes::Show.path(note_id: AuthorizationSpec.note(9)))
      missing.status.should eq(HTTP::Status::NOT_FOUND)
      missing.json["code"].should eq("missing")
    end
  end

  it "answers 403 where the policy forbids, and the Command does not run" do
    AuthorizationSpec.with_db do
      response = AuthorizationSpec.ada.patch(AuthorizationSpec::Notes::Update.path(note_id: AuthorizationSpec.note(3)), json: {body: "changed"})
      response.status.should eq(HTTP::Status::FORBIDDEN)
      response.json["code"].should eq("forbidden")
      response.trace.root["punch.authz"].should eq("forbid")
      AuthorizationSpec.body(3).should eq("Ada's locked")
    end
  end

  it "runs a Command's policy inside its write transaction" do
    AuthorizationSpec.with_db do
      response = AuthorizationSpec.ada.patch(AuthorizationSpec::Notes::Update.path(note_id: AuthorizationSpec.note(1)), json: {body: "changed"})
      response.status.should eq(HTTP::Status::OK)
      AuthorizationSpec.body(1).should eq("changed")
      write = response.trace.spans.find!(&.name.ends_with?(" write"))
      policy_read = response.trace.spans.select { |span| span.attributes["db.query.text"]?.try(&.to_s.includes?("owner_id")) }
      policy_read.should_not be_empty
      policy_read.all? { |span| span.parent_id == write.span_id }.should be_true
    end
  end

  it "answers 401 before the policy when an actor is needed and none is presented" do
    AuthorizationSpec.with_db do
      response = AuthorizationSpec.client.get(AuthorizationSpec::Notes::Show.path(note_id: AuthorizationSpec.note(1)))
      response.status.should eq(HTTP::Status::UNAUTHORIZED)
      response.trace.root["punch.authz"]?.should be_nil
    end
  end

  it "passes a nil actor to the policy of an operation anyone may ask" do
    AuthorizationSpec.with_db do
      AuthorizationSpec.client.get(AuthorizationSpec::Secret.path).json["body"].should eq("nothing")
      AuthorizationSpec.ada.get(AuthorizationSpec::Secret.path).json["body"].should eq("the secret")
    end
  end

  it "makes a grant only by running the policy" do
    AuthorizationSpec.with_db do
      actor = AuthorizationSpec::Actor.new(AuthorizationSpec::UserID.parse(1).as(AuthorizationSpec::UserID))
      Punch::Spec.db.read do |db|
        Punch::Grant(AuthorizationSpec::Notes::Update).check(actor, db, note_id: AuthorizationSpec.note(1)).should be_a(Punch::Grant(AuthorizationSpec::Notes::Update))
        Punch::Grant(AuthorizationSpec::Notes::Update).check(actor, db, note_id: AuthorizationSpec.note(2)).as(Punch::Policy::Refused).code.should eq("not_found")
        Punch::Grant(AuthorizationSpec::Notes::Update).check(actor, db, note_id: AuthorizationSpec.note(3)).as(Punch::Policy::Refused).code.should eq("forbidden")
      end
      Punch::Spec.db.write do |db|
        grant = Punch::Spec.grant(AuthorizationSpec::Notes::Update, actor, db, note_id: AuthorizationSpec.note(1))
        input = Punch::Spec.input(AuthorizationSpec::Notes::Update::Input, {"note_id" => "1"}, body: "direct")
        AuthorizationSpec::Notes::Update.new.call(input, db, actor, grant).body.should eq("direct")
        expect_raises(Exception, /not_found/) do
          Punch::Spec.grant(AuthorizationSpec::Notes::Update, actor, db, note_id: AuthorizationSpec.note(2))
        end
      end
    end
  end

  it "leaves out forms and links the viewer may not use, and counts them" do
    AuthorizationSpec.with_db do
      response = AuthorizationSpec.ada.visit(AuthorizationSpec::Notes::ShowPage.href(note_id: AuthorizationSpec.note(1)))
      response.status.should eq(HTTP::Status::OK)
      html = response.html
      html.find("form").size.should eq(1)
      html.find("a").map { |link| Punch::Spec::HTML.text(link) }.should eq(["Note 1", "Note 3", "Front", "Mine"])
      response.trace.spans.find!(&.name.== "render")["punch.authz.hidden"].should eq(1)

      locked = AuthorizationSpec.ada.visit(AuthorizationSpec::Notes::ShowPage.href(note_id: AuthorizationSpec.note(3))).html
      locked.find("form").should be_empty
    end
  end

  it "hides links and forms that need a signed-in user from a visitor" do
    AuthorizationSpec.with_db do
      html = AuthorizationSpec.client.visit(AuthorizationSpec::Notes::FrontPage.href).html
      html.find("a").map { |link| Punch::Spec::HTML.text(link) }.should eq(["Front"])
      html.find("form").should be_empty
      signed_in = AuthorizationSpec.ada.visit(AuthorizationSpec::Notes::FrontPage.href).html
      signed_in.find("a").size.should eq(2)
      signed_in.find("form").size.should eq(1)
    end
  end

  it "renders everything outside a request, and asks the policies with an authorizer" do
    AuthorizationSpec.with_db do
      view = AuthorizationSpec::Notes::NoteView.new(AuthorizationSpec.note(2), AuthorizationSpec::Note.new("x"))
      Punch::Spec.html(Punch::Spec.render(view)).find("a").size.should eq(5)
      actor = AuthorizationSpec::Actor.new(AuthorizationSpec::UserID.parse(2).as(AuthorizationSpec::UserID))
      Punch::Spec.db.read do |db|
        html = Punch::Spec.html(Punch::Spec.render(view, authorizer: Punch::Policy::Authorizer.new(actor, db)))
        html.find("a").map { |link| Punch::Spec::HTML.text(link) }.should eq(["Note 2", "Front", "Mine"])
        html.find("form").size.should eq(1)
      end
    end
  end

  it "shows a refused form's page again with 403 when the policy forbids its Command" do
    AuthorizationSpec.with_db do
      client = AuthorizationSpec.ada
      response = client.submit(AuthorizationSpec::Notes::Update.action(note_id: AuthorizationSpec.note(3)), {body: "changed"})
      response.status.should eq(HTTP::Status::FORBIDDEN)
      AuthorizationSpec.body(3).should eq("Ada's locked")
    end
  end

  it "documents 403 and 404 on operations with a policy" do
    registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
    entry = ->(operation : String) { Punch::Routing.routes.find!(&.operation.==(operation)) }
    show = Punch::OpenAPI.operation(AuthorizationSpec::Notes::Show, entry.call("AuthorizationSpec::Notes::Show"), registry)["responses"]
    show["403"]["content"]["application/problem+json"]["schema"]["allOf"][1]["properties"]["code"]["const"].should eq("forbidden")
    codes = show["404"]["content"]["application/problem+json"]["schema"]["oneOf"].as_a.map(&.["allOf"][1]["properties"]["code"]["const"])
    codes.should eq(["missing", "not_found"])
    show.as_h.keys.should eq(show.as_h.keys.sort!)
    update = Punch::OpenAPI.operation(AuthorizationSpec::Notes::Update, entry.call("AuthorizationSpec::Notes::Update"), registry)["responses"]
    update["403"]["content"]["application/problem+json"]["schema"]["oneOf"].as_a.map(&.["allOf"][1]["properties"]["code"]["const"]).should eq(["cross_origin_request", "forbidden"])
    secret = Punch::OpenAPI.operation(AuthorizationSpec::Secret, entry.call("AuthorizationSpec::Secret"), registry)["responses"]
    secret["404"]["content"]["application/problem+json"]["schema"]["allOf"][1]["properties"]["code"]["const"].should eq("not_found")
  end

  it "lists each operation's policy in the route table" do
    routes = Punch::Routing.routes.to_h { |route| {route.operation, route} }
    routes["AuthorizationSpec::Notes::Show"].policy.should eq("AuthorizationSpec::Owner")
    routes["AuthorizationSpec::Notes::Create"].policy.should eq("Punch::SignedIn")
    routes["AuthorizationSpec::Notes::FrontPage"].public.should be_true
    routes["AuthorizationSpec::Notes::FrontPage"].policy.should be_nil
  end
end
