require "../spec_helper"
require "../support/auth_schema"
require "http/client"
require "log/spec"

module LiveSpec
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

  struct NoteChanged
    include Punch::Event

    getter note_id : NoteID

    def initialize(@note_id)
    end
  end

  struct Pinged
    include Punch::Event

    def initialize
    end
  end

  # A page's `live` that raises on it: a bug.
  struct Broken
    include Punch::Event

    def initialize
    end
  end

  # Only a note's owner sees it.
  struct Owner
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, *, note_id : NoteID) : Punch::Policy::Decision
      owner = db.query_one?("SELECT owner_id FROM notes WHERE id = ?", note_id.value, &.read(Int64))
      owner == actor.id.value ? allow : not_found
    end
  end

  struct Note
    include JSON::Serializable

    getter id : NoteID
    getter body : String

    def initialize(@id, @body)
    end

    def self.find(db : Punch::Reader, id : NoteID, owner : Actor) : Note?
      db.query_one?("SELECT body FROM notes WHERE id = ? AND owner_id = ?", id.value, owner.id.value) { |row| Note.new(id, row.read(String)) }
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

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Update), events : Punch::Events(NoteChanged)) : Note
        db.exec("UPDATE notes SET body = ? WHERE id = ?", input.body, input.note_id.value)
        events.publish(NoteChanged.new(input.note_id))
        Note.new(input.note_id, input.body)
      end
    end

    # Publishes what the specs need, as a Command would.
    @[Punch::Authorize(Punch::SignedIn)]
    struct Ping < Punch::Command
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Ping), events : Punch::Events(Pinged | Broken)) : Nil
      end
    end

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
        end
      end
    end

    # The signed-in user's notes; a changed one of theirs is replaced.
    @[Punch::Authorize(Punch::SignedIn)]
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

      def live(event : NoteChanged, input : Input, db : Punch::Reader, actor : Actor) : Punch::TurboStream?
        note = Note.find(db, event.note_id, actor) || return
        Punch::TurboStream.build(&.replace(note.id, NoteItem.new(note)))
      end

      def live(event : Pinged, input : Input, db : Punch::Reader, actor : Actor) : Punch::TurboStream?
        Punch::TurboStream.build(&.refresh)
      end

      def live(event : Broken, input : Input, db : Punch::Reader, actor : Actor) : Punch::TurboStream?
        raise "broken"
      end
    end

    # One note, for its owner; the stream ends when it changes hands.
    @[Punch::Authorize(Owner)]
    @[Punch::Forms(Update)]
    struct ShowPage < Punch::Page
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : NoteID
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : NoteList
        NoteList.new([Note.find(db, input.note_id, actor)].compact)
      end

      def live(event : NoteChanged, input : Input, db : Punch::Reader, actor : Actor) : Punch::TurboStream?
        return unless event.note_id == input.note_id

        note = Note.find(db, event.note_id, actor) || return
        Punch::TurboStream.build(&.replace(note.id, NoteItem.new(note)))
      end
    end
  end

  def self.with_db(&)
    AuthSchema.with_spec_db do
      Punch::Spec.db.write { |db| SQL.each_line { |statement| db.exec(statement) } }
      hub = Punch::Live::InProcess.new
      Punch::Live.hub = hub
      yield hub
    end
  end

  def self.client(user : Int32) : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil).sign_in(UserID.parse(user).as(UserID))
  end

  def self.note(id : Int32) : NoteID
    NoteID.parse(id).as(NoteID)
  end

  # Commits *event* as a Command would.
  def self.publish(event : Pinged | Broken) : Nil
    Punch::Spec.db.write { |db| Punch::Spec.events(Notes::Ping, db).publish(event) }
  end
end

describe Punch::Live do
  it "names live pages' surface in the route table" do
    routes = Punch::Routing.routes.to_h { |route| {route.operation, route} }
    routes["LiveSpec::Notes::IndexPage"].surfaces.should eq(["html", "live"])
  end

  it "writes a stream source at the end of a live page, with the hub's position" do
    LiveSpec.with_db do |hub|
      response = LiveSpec.client(1).visit(LiveSpec::Notes::IndexPage.href)
      response.should have_element("body > turbo-stream-source[src='/live_spec/notes?_live=#{hub.boot}-0']")
    end
  end

  it "sends each committed change to an open page, rendered for its viewer" do
    LiveSpec.with_db do
      ada = LiveSpec.client(1)
      live = ada.live(LiveSpec::Notes::IndexPage.href)
      live.status.should eq(HTTP::Status::OK)
      live.response.content_type.should eq("text/event-stream")
      ada.patch(LiveSpec::Notes::Update.path(note_id: LiveSpec.note(1)), json: {body: "Tea"}).status.should eq(HTTP::Status::OK)
      message = live.next
      message.should have_stream_action(:replace, LiveSpec.note(1), containing: "a", text: "Tea")
      # The form asked its policy for Ada.
      message.should have_stream_action(:replace, LiveSpec.note(1), containing: "form")
      live.last_event_id.should_not be_nil
      live.close
    end
  end

  it "sends nothing for a change the page does not show" do
    LiveSpec.with_db do
      live = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
      LiveSpec.client(2).patch(LiveSpec::Notes::Update.path(note_id: LiveSpec.note(2)), json: {body: "Mine"})
      live.next?.should be_nil
      live.close
    end
  end

  it "takes every event type the page's live overloads name" do
    LiveSpec.with_db do
      live = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
      LiveSpec.publish(LiveSpec::Pinged.new)
      live.next.should contain(%(<turbo-stream action="refresh">))
      live.close
    end
  end

  it "skips an event whose rendering fails, logged, and goes on" do
    LiveSpec.with_db do
      live = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
      Log.capture("punch.live") do |logs|
        LiveSpec.publish(LiveSpec::Broken.new)
        LiveSpec.publish(LiveSpec::Pinged.new)
        live.next.should contain(%(<turbo-stream action="refresh">))
        logs.check(:error, /failed on LiveSpec::Broken/)
      end
      live.close
    end
  end

  it "ends the stream once the viewer may no longer see the page" do
    LiveSpec.with_db do
      live = LiveSpec.client(1).live(LiveSpec::Notes::ShowPage.href(note_id: LiveSpec.note(1)))
      live.open?.should be_true
      Punch::Spec.db.write do |db|
        db.exec("UPDATE notes SET owner_id = 2 WHERE id = 1")
        Punch::Spec.events(LiveSpec::Notes::Update, db).publish(LiveSpec::NoteChanged.new(LiveSpec.note(1)))
      end
      live.ended?.should be_true
      live.next?.should be_nil
    end
  end

  it "answers a stream the page would refuse as the page does" do
    LiveSpec.with_db do
      LiveSpec.client(2).live(LiveSpec::Notes::ShowPage.href(note_id: LiveSpec.note(1))).status.should eq(HTTP::Status::NOT_FOUND)
      anonymous = Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
      stream = anonymous.live(LiveSpec::Notes::IndexPage.href)
      stream.status.should eq(HTTP::Status::UNAUTHORIZED)
      stream.open?.should be_false
    end
  end

  it "catches up with what was committed between the page's read and its stream" do
    LiveSpec.with_db do |hub|
      ada = LiveSpec.client(1)
      page = ada.visit(LiveSpec::Notes::IndexPage.href)
      source = page.html.find("turbo-stream-source").first["src"]
      LiveSpec.client(1).patch(LiveSpec::Notes::Update.path(note_id: LiveSpec.note(1)), json: {body: "Between"})
      live = ada.live(source)
      live.next.should have_stream_action(:replace, LiveSpec.note(1), containing: "a", text: "Between")
      live.last_event_id.should eq("#{hub.boot}-1")
      live.close
    end
  end

  it "catches up after a reconnect from the last event the browser saw" do
    LiveSpec.with_db do
      ada = LiveSpec.client(1)
      live = ada.live(LiveSpec::Notes::IndexPage.href)
      ada.patch(LiveSpec::Notes::Update.path(note_id: LiveSpec.note(1)), json: {body: "One"})
      live.next
      seen = live.last_event_id
      live.close
      ada.patch(LiveSpec::Notes::Update.path(note_id: LiveSpec.note(1)), json: {body: "Two"})
      again = ada.live(LiveSpec::Notes::IndexPage.href, last_event_id: seen)
      again.next.should have_stream_action(:replace, LiveSpec.note(1), containing: "a", text: "Two")
      again.next?.should be_nil
      again.close
    end
  end

  it "refreshes a page whose position this process cannot replay" do
    LiveSpec.with_db do
      live = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href, last_event_id: "0000beef-12")
      live.next.should contain(%(<turbo-stream action="refresh">))
      live.close
    end
  end

  it "closes every stream when the hub closes, as a deploy's drain does" do
    LiveSpec.with_db do |hub|
      live = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
      hub.subscribers.should eq(1)
      hub.close
      live.ended?.should be_true
      hub.subscribers.should eq(0)
    end
  end

  it "answers 503 beyond the open streams allowed" do
    LiveSpec.with_db do
      max = Punch::Live.max_streams
      Punch::Live.max_streams = 1
      begin
        first = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
        second = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
        second.status.should eq(HTTP::Status::SERVICE_UNAVAILABLE)
        second.response.headers["Retry-After"].should eq("30")
        first.close
        first.ended?.should be_true
        third = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
        third.status.should eq(HTTP::Status::OK)
        third.close
      ensure
        Punch::Live.max_streams = max
      end
    end
  end
end

describe "Punch::Live, framing" do
  it "keeps a carriage return in rendered text from ending a data line" do
    LiveSpec.with_db do
      ada = LiveSpec.client(1)
      live = ada.live(LiveSpec::Notes::IndexPage.href)
      ada.patch(LiveSpec::Notes::Update.path(note_id: LiveSpec.note(1)), json: {body: "Tea\revent: hijack"}).status.should eq(HTTP::Status::OK)
      live.next.should_not contain('\r')
      live.close
    end
  end
end

describe "Punch::Live, limits" do
  it "ends an idle stream at the keepalive once the viewer lost access, freeing its slot" do
    LiveSpec.with_db do |hub|
      keepalive = Punch::Live.keepalive
      Punch::Live.keepalive = 20.milliseconds
      begin
        live = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
        live.ended?(100.milliseconds).should be_false
        Punch::Spec.db.write(&.exec("DELETE FROM punch_sessions WHERE user_id = 1"))
        live.ended?.should be_true
        hub.subscribers.should eq(0)
      ensure
        Punch::Live.keepalive = keepalive
      end
    end
  end

  it "answers 503 beyond one viewer's streams, while others still get theirs" do
    LiveSpec.with_db do
      max = Punch::Live.max_streams_per_viewer
      Punch::Live.max_streams_per_viewer = 2
      begin
        hog = LiveSpec.client(2)
        streams = Array.new(2) { hog.live(LiveSpec::Notes::IndexPage.href) }
        streams.all?(&.open?).should be_true
        hog.live(LiveSpec::Notes::IndexPage.href).status.should eq(HTTP::Status::SERVICE_UNAVAILABLE)
        other = LiveSpec.client(1).live(LiveSpec::Notes::IndexPage.href)
        other.status.should eq(HTTP::Status::OK)
        closed = streams.pop
        closed.close
        closed.ended?.should be_true
        again = hog.live(LiveSpec::Notes::IndexPage.href)
        again.status.should eq(HTTP::Status::OK)
        (streams + [other, again]).each(&.close)
      ensure
        Punch::Live.max_streams_per_viewer = max
      end
    end
  end

  it "keeps a quarter of the server's connections for other requests" do
    Punch::Live.max_streams.should eq({1000, Punch::HTTP::Config.connection_limit * 3 // 4}.min)
  end
end

describe "Punch::Live over a socket" do
  it "streams chunked server-sent events, and the drain closes them at once" do
    LiveSpec.with_db do |hub|
      router = Punch::Routing::Router.new(Punch::Spec.db)
      server = Punch::HTTP::Server.new(Punch::HTTP::Config.new, Punch::Trace::Tracer.off) { |context| router.call(context) }
      server.on_drain("live") { hub.close }
      port = server.bind(0).port
      stopped = Channel(Nil).new
      spawn { server.run(trap_signals: false); stopped.send(nil) }
      cookie = LiveSpec.client(1).cookies[Punch::Auth::COOKIE]
      headers = HTTP::Headers{"Accept" => "text/event-stream", "Cookie" => "#{Punch::Auth::COOKIE}=#{cookie}"}
      lines = Channel(String?).new(16)
      spawn do
        HTTP::Client.new("127.0.0.1", port).get(LiveSpec::Notes::IndexPage.href.url, headers) do |response|
          response.status_code.should eq(200)
          response.headers["Transfer-Encoding"].should eq("chunked")
          response.headers["Cache-Control"].should eq("no-store")
          while line = response.body_io.gets(chomp: true)
            lines.send(line)
          end
        end
        lines.send(nil)
      end
      lines.receive.should eq("retry: 2000")
      lines.receive.should eq("")
      until hub.subscribers == 1
        Fiber.yield
      end
      LiveSpec.publish(LiveSpec::Pinged.new)
      lines.receive.should eq("id: #{hub.boot}-1")
      lines.receive.should eq(%(data: <turbo-stream action="refresh"></turbo-stream>))
      lines.receive.should eq("")
      begun = Time.instant
      server.shutdown
      stopped.receive
      (Time.instant - begun).should be < 1.second
      lines.receive.should be_nil
    end
  end
end

describe Punch::Live::InProcess do
  it "replays only what it still holds" do
    hub = Punch::Live::InProcess.new
    all = ->(_event : Punch::Event) { true }
    start = hub.position
    (Punch::Live::InProcess::BACKLOG + 1).times { hub.publish(LiveSpec::Pinged.new) }
    hub.since(start, all).should be_a(Punch::Live::Refresh)
    last = Punch::Live::InProcess::BACKLOG + 1
    hub.since("#{hub.boot}-#{last - Punch::Live::InProcess::MAX_REPLAY}", all).as(Array).size.should eq(Punch::Live::InProcess::MAX_REPLAY)
    # More than a stream replays when it opens: the page refreshes instead.
    hub.since("#{hub.boot}-#{last - Punch::Live::InProcess::MAX_REPLAY - 1}", all).should be_a(Punch::Live::Refresh)
    hub.since(hub.position, all).should eq([] of Punch::Live::Entry)
    hub.since("#{hub.boot}-99999", all).should be_a(Punch::Live::Refresh)
    hub.since("nonsense", all).should be_a(Punch::Live::Refresh)
  end

  it "marks a subscription that fell behind instead of waiting for it" do
    hub = Punch::Live::InProcess.new
    subscription = hub.subscribe(->(_event : Punch::Event) { true })
    (Punch::Live::Subscription::CAPACITY + 1).times { hub.publish(LiveSpec::Pinged.new) }
    subscription.overflowed!.should be_true
    subscription.overflowed!.should be_false
  end
end
