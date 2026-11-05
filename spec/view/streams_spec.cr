require "../spec_helper"
require "../support/auth_schema"

module StreamsSpec
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
    CREATE TABLE notes (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, body TEXT NOT NULL) STRICT;
    INSERT INTO notes (id, owner_id, body) VALUES (1, 1, 'Ada''s'), (2, 2, 'Grace''s');
    SQL

  # Only a note's owner sees it; a note that does not exist (yet) is
  # nobody's.
  struct Owner
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, *, note_id : NoteID) : Punch::Policy::Decision
      owner = db.query_one?("SELECT owner_id FROM notes WHERE id = ?", note_id.value, &.read(Int64))
      owner == actor.id.value ? allow : not_found
    end
  end

  @[Punch::Status(200)]
  struct Note
    include JSON::Serializable

    getter id : NoteID
    getter body : String

    def initialize(@id, @body)
    end
  end

  @[Punch::Status(409)]
  struct Empty
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(200)]
  struct Removed
    include JSON::Serializable

    def initialize
    end
  end

  module Notes
    @[Punch::Authorize(Owner)]
    struct Update < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : NoteID

        getter body : String
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Update)) : Note | Removed | Empty
        return Empty.new if input.body.blank?
        return Removed.new if input.body == "gone"

        db.exec("UPDATE notes SET body = ? WHERE id = ?", input.body, input.note_id.value)
        Note.new(input.note_id, input.body)
      end
    end

    @[Punch::Authorize(Punch::SignedIn)]
    @[Punch::Idempotency(:required)]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter body : String
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Create)) : Note
        id = db.query_one?("INSERT INTO notes (owner_id, body) VALUES (?, ?) RETURNING id", actor.id.value, input.body, &.read(Int64)) || raise "no id"
        Note.new(NoteID.parse(id).as(NoteID), input.body)
      end
    end

    # A note as a list item: its text, a link to it, and its edit form,
    # which ask their policies.
    struct NoteItem
      include Punch::Component

      def initialize(@note : Note)
      end

      def view(v : Punch::View) : Nil
        v.li(id: Punch.dom_id(@note.id)) do
          v.a @note.body, href: ShowPage.href(note_id: @note.id)
          v.form(Update.action(note_id: @note.id)) { |form| form.field :body; form.submit "Save" }
        end
      end
    end

    struct NoteList
      include Punch::Component

      def initialize(@notes : Array(Note))
      end

      def view(v : Punch::View) : Nil
        v.document("Notes") do
          v.ul(id: "notes") { @notes.each { |note| v.render(NoteItem.new(note)) } }
          v.form(Create.action) { |form| form.field :body; form.submit "Add" }
        end
      end
    end

    @[Punch::Authorize(Punch::SignedIn)]
    @[Punch::Forms(Update, Create)]
    struct IndexPage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : NoteList
        notes = db.query_all("SELECT id, body FROM notes WHERE owner_id = ? ORDER BY id", actor.id.value) do |row|
          Note.new(NoteID.parse(row.read(Int64)).as(NoteID), row.read(String))
        end
        NoteList.new(notes)
      end

      # A note is shown changed, and added to the list (as made by
      # Create); one sent with "redirect" as its text goes the old way.
      def self.stream(result : Note) : Punch::TurboStream?
        return if result.body == "redirect"

        Punch::TurboStream.build do |stream|
          stream.replace result.id, NoteItem.new(result), morph: true
          stream.append "notes", NoteItem.new(result)
        end
      end
    end

    @[Punch::Authorize(Owner)]
    struct ShowPage < Punch::Page
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : NoteID
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : NoteList
        NoteList.new([] of Note)
      end
    end
  end

  struct Raw
    include Punch::Component

    def view(v : Punch::HTMLView) : Nil
      v.p { v.raw Punch::SafeHTML.trusted("<b>bold</b>") }
    end
  end

  struct Whole
    include Punch::Component

    def view(v : Punch::View) : Nil
      v.document("Whole") { v.p "x" }
    end
  end

  def self.with_db(&)
    AuthSchema.with_spec_db do
      Punch::Migrations::Schema.load(Punch::Spec.db, Punch::IdempotencyKeys.sql, "idempotency")
      Punch::Spec.db.write { |db| SQL.each_line { |statement| db.exec(statement) } }
      yield
    end
  end

  def self.ada : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil).sign_in(UserID.parse(1).as(UserID))
  end

  def self.note(id : Int32) : NoteID
    NoteID.parse(id).as(NoteID)
  end
end

describe Punch::TurboStream do
  it "writes each action with its target and the component as HTML in a template" do
    note = StreamsSpec::Note.new(StreamsSpec.note(7), "Tea & cake")
    stream = Punch::TurboStream.build do |actions|
      actions.append "notes", StreamsSpec::Notes::NoteItem.new(note)
      actions.update StreamsSpec.note(7), StreamsSpec::Raw.new, morph: true
      actions.remove Punch.dom_id(StreamsSpec.note(8), "lines")
      actions.refresh
    end
    html = Punch::Spec.render(stream)
    html.should start_with(%(<turbo-stream action="append" target="notes"><template><li id="streams_spec_7">))
    html.should contain(%(<a href="/streams_spec/notes/7">Tea &amp; cake</a>))
    html.should contain(%(<turbo-stream action="update" target="streams_spec_7" method="morph"><template><p><b>bold</b></p>\n</template></turbo-stream>))
    html.should contain(%(<turbo-stream action="remove" target="lines_streams_spec_8"></turbo-stream>\n))
    html.should end_with(%(<turbo-stream action="refresh"></turbo-stream>\n))
    html.should have_stream_action(:append, "notes", containing: "li > a", text: "Tea & cake")
    html.should have_stream_action(:remove, Punch.dom_id(StreamsSpec.note(8), "lines"))
  end

  it "refuses a target that is not a DOM ID" do
    expect_raises(ArgumentError, /DOM ID/) { Punch::TurboStream.new.remove("two words") }
    expect_raises(ArgumentError, /DOM ID/) { Punch::TurboStream.new.remove("") }
  end

  it "carries parts of a page, never a document" do
    expect_raises(Punch::View::NestingError, /not a document/) do
      Punch::TurboStream.new.replace("main", StreamsSpec::Whole.new).render
    end
  end

  it "escapes a target" do
    Punch::Spec.render(Punch::TurboStream.new.remove(%(a"b))).should contain(%(target="a&quot;b"))
  end
end

describe "Turbo Stream answers to forms" do
  it "answers a form Turbo sent with the page's stream, rendered for the actor" do
    StreamsSpec.with_db do
      response = StreamsSpec.ada.submit(StreamsSpec::Notes::Update.action(note_id: StreamsSpec.note(1)), {body: "Tea"}, stream: true)
      response.status.should eq(HTTP::Status::OK)
      response.headers["Content-Type"].should eq("text/vnd.turbo-stream.html; charset=utf-8")
      response.headers["Vary"].should contain("Accept")
      response.should have_stream_action(:replace, StreamsSpec.note(1), containing: "li form input[name=body]")
      response.should have_stream_action(:append, "notes", containing: "a", text: "Tea")
      render = response.trace.spans.find!(&.name.== "render")
      render["punch.view"].should eq("Punch::TurboStream")
      render["punch.stream.actions"].should eq(2)
    end
  end

  it "redirects a browser without Turbo, and a client that only accepts anything" do
    StreamsSpec.with_db do
      update = StreamsSpec::Notes::Update.action(note_id: StreamsSpec.note(1))
      StreamsSpec.ada.submit(update, {body: "Tea"}).should redirect_to(StreamsSpec::Notes::IndexPage.href)
      StreamsSpec.ada.submit(update, {body: "Tea"}, headers: HTTP::Headers{"Accept" => "*/*"}).should redirect_to(StreamsSpec::Notes::IndexPage.href)
      StreamsSpec.ada.submit(update, {body: "Tea"}, headers: HTTP::Headers{"Accept" => "text/vnd.turbo-stream.html;q=0, text/html"})
        .should redirect_to(StreamsSpec::Notes::IndexPage.href)
    end
  end

  it "redirects when the page has no stream for the result, or gives none" do
    StreamsSpec.with_db do
      update = StreamsSpec::Notes::Update.action(note_id: StreamsSpec.note(1))
      StreamsSpec.ada.submit(update, {body: "gone"}, stream: true).should redirect_to(StreamsSpec::Notes::IndexPage.href)
      StreamsSpec.ada.submit(update, {body: "redirect"}, stream: true).should redirect_to(StreamsSpec::Notes::IndexPage.href)
    end
  end

  it "shows a refusal as the page again, as without streams" do
    StreamsSpec.with_db do
      response = StreamsSpec.ada.submit(StreamsSpec::Notes::Update.action(note_id: StreamsSpec.note(1)), {body: " "}, stream: true)
      response.status.should eq(HTTP::Status::CONFLICT)
      response.content_type.should eq("text/html")
      response.should have_element("ul#notes")
    end
  end

  it "renders in the Command's transaction when the answer is stored for an idempotency key" do
    StreamsSpec.with_db do
      client = StreamsSpec.ada
      key = Random::Secure.urlsafe_base64(18)
      form = {Punch::IdempotencyKeys::FIELD => key}
      first = client.submit(StreamsSpec::Notes::Create.action, {body: "New"}, form: form, stream: true)
      first.status.should eq(HTTP::Status::OK)
      # The link to the new note asks its policy, which reads the note
      # the Command wrote: only visible from inside its transaction.
      first.should have_stream_action(:append, "notes", containing: "li > a", text: "New")
      replay = client.submit(StreamsSpec::Notes::Create.action, {body: "New"}, form: form, stream: true)
      replay.body.should eq(first.body)
      replay.headers["Content-Type"].should eq(first.headers["Content-Type"])
    end
  end
end
