require "../spec_helper"
require "../../src/punch/cli/tool"

module EventsSpec
  SQL = <<-SQL
    CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT;
    CREATE TABLE audit (kind TEXT NOT NULL, note_id INTEGER NOT NULL) STRICT;
    SQL

  # A marker several events share; one subscriber listens to all of them.
  module Audited
    abstract def note_id : Int64
  end

  struct NoteAdded
    include Punch::Event
    include Audited

    getter note_id : Int64
    getter body : String

    def initialize(@note_id, @body)
    end
  end

  struct NoteRemoved
    include Punch::Event
    include Audited

    getter note_id : Int64

    def initialize(@note_id)
    end
  end

  # An abstract event: subscribers to it get every concrete one.
  abstract struct Lifecycle
    include Punch::Event
  end

  struct NoteArchived < Lifecycle
    getter note_id : Int64

    def initialize(@note_id)
    end
  end

  # Published by nobody: what the `events` step of `punch check` reports.
  struct NoteForgotten
    include Punch::Event

    def initialize
    end
  end

  # What after-commit subscribers saw, by note body; bodies are unique per
  # example, so parallel examples do not meet.
  SEEN = {} of String => Array(String)
  LOCK = Mutex.new

  def self.seen(body : String) : Array(String)
    LOCK.synchronize { SEEN[body]?.try(&.dup) || [] of String }
  end

  def self.saw(body : String, subscriber : String) : Nil
    LOCK.synchronize { (SEEN[body] ||= [] of String) << subscriber }
  end

  @[Punch::Subscriber::Delivery(:inline)]
  struct Audit
    include Punch::Subscriber(Audited)

    def call(event : Audited, db : Punch::Writer) : Nil
      db.exec("INSERT INTO audit (kind, note_id) VALUES (?, ?)", event.class.name.split("::").last, event.note_id)
    end
  end

  # Refuses a body inline, so the Command fails with it.
  @[Punch::Subscriber::Delivery(:inline)]
  struct Veto
    include Punch::Subscriber(NoteAdded)

    def call(event : NoteAdded, db : Punch::Writer) : Nil
      raise "vetoed" if event.body.starts_with?("veto")
    end
  end

  # Runs after commit; fails on some bodies, which must not stop Recorder.
  struct Explode
    include Punch::Subscriber(NoteAdded)

    def call(event : NoteAdded) : Nil
      raise "exploded" if event.body.starts_with?("explode")
      EventsSpec.saw(event.body, "Explode")
    end
  end

  struct Recorder
    include Punch::Subscriber(NoteAdded)

    def call(event : NoteAdded) : Nil
      EventsSpec.saw(event.body, "Recorder")
    end
  end

  struct Lifecycles
    include Punch::Subscriber(Lifecycle)

    def call(event : Lifecycle) : Nil
      EventsSpec.saw("lifecycle", event.class.name)
    end
  end

  # Cache entries the notes' events make stale.
  BODIES = Punch::Cache(Int64, String).new("events_bodies", ttl: 1.minute)
  COUNTS = Punch::Cache(String, Int32).new("events_counts", ttl: 1.minute, tier: :both)

  # Through a marker module: every audited event forgets its note's body.
  @[Punch::Subscriber::Forget(BODIES, key: note_id)]
  struct ForgetBody
    include Punch::Subscriber(Audited)
  end

  # Without a key: a new note clears every count.
  @[Punch::Subscriber::Forget(COUNTS)]
  struct ForgetCounts
    include Punch::Subscriber(NoteAdded)
  end

  @[Punch::Status(422)]
  struct Refused
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(200)]
  struct Added
    include JSON::Serializable

    getter id : Int64

    def initialize(@id)
    end
  end

  module Notes
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter body : String
      end

      # Publishes, then refuses bodies starting with "refuse": a failure
      # result rolls the transaction back, so nothing is delivered.
      def call(input : Input, db : Punch::Writer, events : Punch::Events(NoteAdded)) : Added | Refused
        id = db.query_one?("INSERT INTO notes (body) VALUES (?) RETURNING id", input.body, &.read(Int64)) || raise "the insert returned no row"
        events.publish(NoteAdded.new(id, input.body))
        return Refused.new if input.body.starts_with?("refuse")

        Added.new(id)
      end
    end

    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Destroy < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : Int64
      end

      def call(input : Input, db : Punch::Writer, events : Punch::Events(NoteRemoved | NoteArchived)) : Nil
        db.exec("DELETE FROM notes WHERE id = ?", input.note_id)
        events.publish(NoteArchived.new(input.note_id))
        events.publish(NoteRemoved.new(input.note_id))
      end
    end
  end

  def self.with_db(& : Punch::Database ->) : Nil
    Punch::Spec.database do |database|
      Punch::Migrations::Schema.load(database, SQL, "events")
      yield database
    end
  end

  def self.client(database : Punch::Database, raise_errors : Bool = true) : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(database), openapi: nil, raise_errors: raise_errors)
  end

  def self.count(database : Punch::Database, table : String) : Int64
    database.read(&.query_one?("SELECT count(*) FROM #{table}", &.read(Int64))) || 0_i64
  end

  # Creates a note through the router, and returns the response and what
  # was delivered after commit.
  def self.create(database : Punch::Database, body : String) : {Punch::Spec::Response, Array(Punch::Event)}
    response = nil
    published = Punch::Spec.published { response = client(database, raise_errors: false).post(Notes::Create.path, json: {body: body}) }
    {response || raise("no response"), published}
  end

  def self.unique(prefix : String) : String
    "#{prefix} #{Random::Secure.hex(6)}"
  end
end

describe "Domain events" do
  it "delivers inline in the transaction and the others after it commits" do
    EventsSpec.with_db do |database|
      body = EventsSpec.unique("hello")
      response, events = EventsSpec.create(database, body)
      response.status.should eq(HTTP::Status::OK)
      published = events.compact_map(&.as?(EventsSpec::NoteAdded))
      published.map(&.body).should eq([body])
      published.first.note_id.should eq(response.json["id"].as_i64)
      EventsSpec.seen(body).should eq(["Explode", "Recorder"])
      database.read(&.query_all("SELECT kind FROM audit", &.read(String))).should eq(["NoteAdded"])

      trace = response.trace
      trace.root["punch.events.published"].should eq(1)
      publish = trace["publish EventsSpec::NoteAdded"]
      write = trace.spans.find!(&.name.ends_with?(" write"))
      publish.parent_id.should eq(write.span_id)
      publish["punch.event"].should eq("EventsSpec::NoteAdded")
      trace["EventsSpec::Audit"].parent_id.should eq(publish.span_id)
      trace["EventsSpec::Audit"]["punch.delivery"].should eq("inline")
      record = trace["EventsSpec::Recorder"]
      record["punch.delivery"].should eq("after_commit")
      # After the commit: below the operation's span, not the transaction.
      record.parent_id.should_not eq(write.span_id)
      record.start_time.should be >= write.start_time + (write.duration || raise "the write span is unfinished")
    end
  end

  it "delivers nothing after commit when the Command fails, and rolls back what inline subscribers wrote" do
    EventsSpec.with_db do |database|
      body = EventsSpec.unique("refuse")
      response, published = EventsSpec.create(database, body)
      response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      published.should be_empty
      EventsSpec.seen(body).should be_empty
      EventsSpec.count(database, "notes").should eq(0)
      EventsSpec.count(database, "audit").should eq(0)
    end
  end

  it "fails the Command when an inline subscriber raises" do
    EventsSpec.with_db do |database|
      body = EventsSpec.unique("veto")
      response, published = EventsSpec.create(database, body)
      response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
      response.trace["EventsSpec::Veto"].status.should eq(Punch::Trace::Status::Error)
      published.should be_empty
      EventsSpec.seen(body).should be_empty
      EventsSpec.count(database, "notes").should eq(0)
    end
  end

  it "keeps the response and the other subscribers when one fails after commit" do
    EventsSpec.with_db do |database|
      body = EventsSpec.unique("explode")
      response = EventsSpec.client(database).post(EventsSpec::Notes::Create.path, json: {body: body})
      response.status.should eq(HTTP::Status::OK)
      EventsSpec.count(database, "notes").should eq(1)
      EventsSpec.seen(body).should eq(["Recorder"])
      response.trace.root["punch.events.failed"].should eq(1)
      failed = response.trace["EventsSpec::Explode"]
      failed.status.should eq(Punch::Trace::Status::Error)
      failed["exception.message"].should eq("exploded")
    end
  end

  it "delivers to subscribers of a shared module and of an abstract event" do
    EventsSpec.with_db do |database|
      client = EventsSpec.client(database)
      id = client.post(EventsSpec::Notes::Create.path, json: {body: EventsSpec.unique("note")}).json["id"].as_i64
      published = Punch::Spec.published { client.delete(EventsSpec::Notes::Destroy.path(note_id: id)).status.should eq(HTTP::Status::NO_CONTENT) }
      published.map(&.class.name).should eq(%w[EventsSpec::NoteArchived EventsSpec::NoteRemoved])
      database.read(&.query_all("SELECT kind FROM audit ORDER BY rowid", &.read(String))).should eq(%w[NoteAdded NoteRemoved])
      EventsSpec.seen("lifecycle").should contain("EventsSpec::NoteArchived")
    end
  end

  it "delivers after a write a spec runs itself, with the Command's handle" do
    EventsSpec.with_db do |database|
      body = EventsSpec.unique("direct")
      input = Punch::Spec.input(EventsSpec::Notes::Create::Input, body: body)
      published = Punch::Spec.published(EventsSpec::NoteAdded) do
        database.write do |writer|
          EventsSpec::Notes::Create.new.call(input, writer, Punch::Spec.events(EventsSpec::Notes::Create, writer))
          EventsSpec.seen(body).should be_empty # not yet: the transaction is open
        end
      end
      published.map(&.body).should eq([body])
      EventsSpec.seen(body).should eq(["Explode", "Recorder"])

      raised = EventsSpec.unique("raised")
      Punch::Spec.published do
        expect_raises(Exception, "after publishing") do
          database.write do |writer|
            EventsSpec::Notes::Create.new.call(Punch::Spec.input(EventsSpec::Notes::Create::Input, body: raised), writer,
              Punch::Spec.events(EventsSpec::Notes::Create, writer))
            raise "after publishing"
          end
        end
      end.should be_empty
      EventsSpec.seen(raised).should be_empty
    end
  end

  it "forgets cache entries after commit for subscribers with @[Punch::Subscriber::Forget], and keeps them on a rollback" do
    EventsSpec.with_db do |database|
      EventsSpec::COUNTS.fetch("all") { 1 }
      EventsSpec::BODIES.fetch(1_i64) { "old" }
      EventsSpec::BODIES.fetch(2_i64) { "other" }
      response, _ = EventsSpec.create(database, EventsSpec.unique("refuse"))
      response.status.code.should eq(422)
      EventsSpec::COUNTS.cached?("all").should be_true

      response, _ = EventsSpec.create(database, EventsSpec.unique("fresh"))
      response.json["id"].should eq(1) # the refused insert rolled back
      EventsSpec::COUNTS.cached?("all").should be_false
      {EventsSpec::BODIES.cached?(1_i64), EventsSpec::BODIES.cached?(2_i64)}.should eq({false, true})
      response.trace["EventsSpec::ForgetBody"]["punch.delivery"].should eq("after_commit")

      EventsSpec::BODIES.fetch(1_i64) { "again" }
      EventsSpec.client(database).delete(EventsSpec::Notes::Destroy.path(note_id: 1_i64)).status.code.should eq(204)
      {EventsSpec::BODIES.cached?(1_i64), EventsSpec::BODIES.cached?(2_i64)}.should eq({false, true})
    end
  end

  it "refuses a handle used after its transaction" do
    EventsSpec.with_db do |database|
      kept = database.write { |writer| Punch::Spec.events(EventsSpec::Notes::Create, writer) }
      expect_raises(Punch::Database::Error, "used after its block ended") do
        kept.publish(EventsSpec::NoteAdded.new(1, "late"))
      end
    end
  end

  it "knows the graph: publishers from `call`, subscribers with their delivery" do
    graph = Punch::Subscribers.graph.to_h { |node| {node.event, node} }
    graph.keys.select(&.starts_with?("EventsSpec::")).sort!.should eq(%w[
      EventsSpec::NoteAdded EventsSpec::NoteArchived EventsSpec::NoteForgotten EventsSpec::NoteRemoved])
    added = graph["EventsSpec::NoteAdded"]
    added.publishers.should eq(["EventsSpec::Notes::Create"])
    added.subscribers.should eq([{"EventsSpec::Audit", "inline"}, {"EventsSpec::Explode", "after_commit"},
                                 {"EventsSpec::ForgetBody", "after_commit"}, {"EventsSpec::ForgetCounts", "after_commit"},
                                 {"EventsSpec::Recorder", "after_commit"}, {"EventsSpec::Veto", "inline"}])
    added.forgets.should eq([{"EventsSpec::ForgetBody", "events_bodies"}, {"EventsSpec::ForgetCounts", "events_counts"}])
    graph["EventsSpec::NoteRemoved"].forgets.should eq([{"EventsSpec::ForgetBody", "events_bodies"}])
    graph["EventsSpec::NoteArchived"].subscribers.should eq([{"EventsSpec::Lifecycles", "after_commit"}])
    graph["EventsSpec::NoteRemoved"].publishers.should eq(["EventsSpec::Notes::Destroy"])
    graph["EventsSpec::NoteForgotten"].publishers.should be_empty
  end

  it "prints the graph with `events`, and `punch check` fails on an event nobody publishes" do
    stdout, stderr = IO::Memory.new, IO::Memory.new
    Punch::CLI.run(["events", "--json"], stdout, stderr, commands: Punch::CLI::APP_COMMANDS).should eq(0)
    events = JSON.parse(stdout.to_s)["events"].as_a
    added = events.find!(&.["event"].==("EventsSpec::NoteAdded"))
    added["publishers"].should eq(["EventsSpec::Notes::Create"])
    added["subscribers"][0].should eq({"subscriber" => "EventsSpec::Audit", "delivery" => "inline", "forgets" => nil})
    added["subscribers"][2].should eq({"subscriber" => "EventsSpec::ForgetBody", "delivery" => "after_commit", "forgets" => "events_bodies"})

    ok, detail = Punch::CLI::Commands::Check.events(events)
    ok.should be_false
    detail.should contain("EventsSpec::NoteForgotten")
    published = events.reject(&.["publishers"].as_a.empty?)
    Punch::CLI::Commands::Check.events(published).should eq(
      {true, "#{published.size} events published, #{published.sum(&.["subscribers"].as_a.size)} subscriptions"})

    text = IO::Memory.new
    Punch::CLI.run(["events"], text, stderr, commands: Punch::CLI::APP_COMMANDS).should eq(0)
    text.to_s.should contain("EventsSpec::NoteAdded\n  published by  EventsSpec::Notes::Create\n  inline        EventsSpec::Audit\n")
    text.to_s.should contain("EventsSpec::NoteForgotten\n  published by nobody\n")
    text.to_s.should contain("  after_commit  EventsSpec::ForgetBody  (forgets cache events_bodies)\n")
  end

  it "leaves Punch's own unpublished events out of the check unless the app subscribes to them" do
    node = ->(event : String, subscribers : Array(String)) do
      JSON.parse({event: event, publishers: [] of String, subscribers: subscribers.map { |name| {subscriber: name, delivery: "inline"} }}.to_json)
    end
    ok, _ = Punch::CLI::Commands::Check.events([node.call("Punch::Auth::SignInSucceeded", [] of String), node.call("Punch::Auth::SignInFailed", ["Punch::Ops::Count"])])
    ok.should be_true
    ok, detail = Punch::CLI::Commands::Check.events([node.call("Punch::Auth::SignInSucceeded", ["Audit::Log"])])
    ok.should be_false
    detail.should contain("Punch::Auth::SignInSucceeded (subscribers: Audit::Log)")
  end
end
