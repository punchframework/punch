require "../spec_helper"
require "../support/auth_schema"

module IdempotencySpec
  SQL = AuthSchema::SQL + Punch::IdempotencyKeys.sql + Punch::Job::Outbox.sql + <<-SQL
    CREATE TABLE notes (id INTEGER PRIMARY KEY, user_id INTEGER, body TEXT NOT NULL) STRICT;

    SQL

  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  @[Punch::Status(200)]
  struct Noted
    include JSON::Serializable

    getter id : Int64
    getter notes : Int64

    def initialize(@id, @notes)
    end
  end

  # A failure result: rolled back, and stored all the same.
  @[Punch::Status(409)]
  struct Full
    include JSON::Serializable

    getter notes : Int64

    def initialize(@notes)
    end
  end

  struct Follow
    include Punch::Job

    getter note_id : Int64

    def initialize(@note_id)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  # Adds a note and enqueues a follow-up; at most three notes.
  @[Punch::Public]
  struct Notes::Create < Punch::Command
    struct Input
      include Punch::Input

      getter body : String
      getter? explode : Bool = false
    end

    def call(input : Input, db : Punch::Writer, actor : Actor, jobs : Punch::Jobs(Follow)) : Noted | Full
      count = db.query_one?("SELECT count(*) FROM notes", &.read(Int64)) || 0_i64
      return Full.new(count) if count >= 3

      id = db.exec("INSERT INTO notes (user_id, body) VALUES (?, ?)", actor.principal.user_id, input.body).last_insert_id
      raise "exploded after writing" if input.explode?
      jobs.enqueue(Follow.new(id))
      Noted.new(id, count + 1)
    end
  end

  @[Punch::Idempotency(:required)]
  @[Punch::Public]
  struct Notes::Publish < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Actor) : Nil
      db.exec("INSERT INTO notes (user_id, body) VALUES (?, 'published')", actor.principal.user_id)
    end
  end

  # Anyone may write; keys are scoped by address.
  @[Punch::Idempotency(scope: :ip)]
  @[Punch::RateLimitExempt("spec")]
  @[Punch::Public]
  struct Guestbook::Sign < Punch::Command
    struct Input
      include Punch::Input

      getter body : String
    end

    def call(input : Input, db : Punch::Writer) : Noted
      Noted.new(db.exec("INSERT INTO notes (body) VALUES (?)", input.body).last_insert_id, 0_i64)
    end
  end

  # No caller and no scope: takes no keys.
  @[Punch::RateLimitExempt("spec")]
  @[Punch::Public]
  struct Guestbook::Clear < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Nil
      db.exec("DELETE FROM notes")
    end
  end

  # Anyone may call; only a signed-in caller has a scope for keys.
  @[Punch::RateLimitExempt("spec")]
  @[Punch::Public]
  struct Guestbook::Touch < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Actor?) : Nil
      db.exec("INSERT INTO notes (body) VALUES ('touched')")
    end
  end

  @[Punch::Public]
  struct Notes::CreatePage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, actor : Actor) : Form
      Form.new
    end

    struct Form
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.document(title: "Notes") do
          v.form(Notes::Create.action, idempotent: true) do |form|
            form.field :body
            form.submit "Add"
          end
        end
      end
    end
  end

  def self.client(raise_errors : Bool = true) : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil, raise_errors: raise_errors)
  end

  def self.notes : Int64
    Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM notes", &.read(Int64))) || 0_i64
  end

  def self.outbox : Int64
    Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM punch_outbox", &.read(Int64))) || 0_i64
  end

  def self.keys : Int64
    Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM punch_idempotency_keys", &.read(Int64))) || 0_i64
  end

  def self.with_spec_db(&)
    path = File.tempname("idempotency-spec", ".sql")
    File.write(path, SQL)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    begin
      Punch::Spec.db.write(&.exec("INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace')"))
      yield
    ensure
      Punch::Spec.schema = previous
      File.delete(path)
    end
  end
end

private def create(client : Punch::Spec::Client, body : String, key : String?, explode : Bool = false) : Punch::Spec::Response
  headers = key ? Punch::Spec.idempotency_key(key) : nil
  client.post(IdempotencySpec::Notes::Create.path, json: {body: body, explode: explode}, headers: headers)
end

describe "Idempotency keys" do
  it "runs a Command once under a key and replays its answer, writes and outbox entries included" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client.sign_in(1)
      first, again = client.twice("POST", IdempotencySpec::Notes::Create.path, json: {body: "hi"})
      first.status.should eq(HTTP::Status::OK)
      first.replayed?.should be_false
      again.should be_replay_of(first)
      IdempotencySpec.notes.should eq(1)
      IdempotencySpec.outbox.should eq(1)
      first.trace.root["punch.idempotency"].should eq("stored")
      again.trace.root["punch.idempotency"].should eq("replayed")
      # Without a key, or under another, it runs again.
      create(client, "hi", nil).replayed?.should be_false
      create(client, "hi", "other").replayed?.should be_false
      IdempotencySpec.notes.should eq(3)
    end
  end

  it "accepts the key quoted, as the IETF draft writes it" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client.sign_in(1)
      first = create(client, "hi", "k-1")
      create(client, "hi", %("k-1")).should be_replay_of(first)
      IdempotencySpec.notes.should eq(1)
    end
  end

  it "answers 422 for a key reused with another body or path, and runs nothing" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client.sign_in(1)
      create(client, "hi", "k-1")
      reused = create(client, "bye", "k-1")
      reused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      reused.json["code"].should eq("idempotency_key_reused")
      reused.json["detail"].should eq("This Idempotency-Key was used for a different request.")
      IdempotencySpec.notes.should eq(1)
    end
  end

  it "scopes keys per caller and per operation" do
    IdempotencySpec.with_spec_db do
      create(IdempotencySpec.client.sign_in(1), "hi", "k-1")
      other = create(IdempotencySpec.client.sign_in(2), "hi", "k-1")
      other.replayed?.should be_false
      IdempotencySpec.notes.should eq(2)
      published = IdempotencySpec.client.sign_in(1).post(IdempotencySpec::Notes::Publish.path, headers: Punch::Spec.idempotency_key("k-1"))
      published.status.should eq(HTTP::Status::NO_CONTENT)
      published.replayed?.should be_false
      IdempotencySpec.keys.should eq(3)
    end
  end

  it "stores a failure result although its writes roll back, and replays it" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client.sign_in(1)
      3.times { |index| create(client, "n#{index}", nil) }
      full = create(client, "more", "k-full")
      full.status.should eq(HTTP::Status::CONFLICT)
      full.json["code"].should eq("full")
      Punch::Spec.db.write(&.exec("DELETE FROM notes"))
      # The state changed, but the answer under the key stays.
      create(client, "more", "k-full").should be_replay_of(full)
      IdempotencySpec.notes.should eq(0)
      IdempotencySpec.outbox.should eq(3)
    end
  end

  it "stores nothing when the Command raises, so the retry runs" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client(raise_errors: false).sign_in(1)
      create(client, "boom", "k-1", explode: true).status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
      IdempotencySpec.keys.should eq(0)
      IdempotencySpec.notes.should eq(0)
      # A retry with the same request runs; the body still asks to explode,
      # so this one is a new request under a new key.
      create(client, "boom", "k-2").status.should eq(HTTP::Status::OK)
      IdempotencySpec.notes.should eq(1)
    end
  end

  it "stores nothing for answers before the Command runs: bad input, no caller, rate limits" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client
      client.post(IdempotencySpec::Notes::Create.path, json: {body: 7}, headers: Punch::Spec.idempotency_key("k-1"))
        .status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      create(client, "hi", "k-1").status.should eq(HTTP::Status::UNAUTHORIZED)
      IdempotencySpec.keys.should eq(0)
      create(client.sign_in(1), "hi", "k-1").status.should eq(HTTP::Status::OK)
    end
  end

  it "answers 400 for a missing required key and for one that does not parse" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client.sign_in(1)
      missing = client.post(IdempotencySpec::Notes::Publish.path)
      missing.status.should eq(HTTP::Status::BAD_REQUEST)
      missing.json["code"].should eq("idempotency_key_required")
      ["", "with space", "x" * 256, "ü"].each do |bad|
        refused = create(client, "hi", bad)
        refused.status.should eq(HTTP::Status::BAD_REQUEST)
        refused.json["code"].should eq("invalid_idempotency_key")
      end
      IdempotencySpec.notes.should eq(0)
      create(client, "hi", "x" * 255).status.should eq(HTTP::Status::OK)
    end
  end

  it "takes keys from anonymous callers only where the Command names a scope" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client
      first, again = client.twice("POST", IdempotencySpec::Guestbook::Sign.path, json: {body: "hello"}, key: "k-1")
      again.should be_replay_of(first)
      # Another address is another scope.
      other = Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil, peer: "10.0.0.9")
      other.post(IdempotencySpec::Guestbook::Sign.path, json: {body: "hello"}, headers: Punch::Spec.idempotency_key("k-1")).replayed?.should be_false
      IdempotencySpec.notes.should eq(2)

      refused = client.post(IdempotencySpec::Guestbook::Clear.path, headers: Punch::Spec.idempotency_key("k-1"))
      refused.status.should eq(HTTP::Status::BAD_REQUEST)
      refused.json["code"].should eq("idempotency_key_not_accepted")
      anonymous = client.post(IdempotencySpec::Guestbook::Touch.path, headers: Punch::Spec.idempotency_key("k-1"))
      anonymous.json["code"].should eq("idempotency_key_not_accepted")
      IdempotencySpec.notes.should eq(2)
      client.sign_in(1).post(IdempotencySpec::Guestbook::Touch.path, headers: Punch::Spec.idempotency_key("k-1"))
        .status.should eq(HTTP::Status::NO_CONTENT)
    end
  end

  it "treats an expired key as new, and the purge job removes it" do
    IdempotencySpec.with_spec_db do
      clock = Punch::Spec.clock
      client = IdempotencySpec.client.sign_in(1)
      create(client, "hi", "k-1")
      clock.advance(23.hours)
      create(client, "hi", "k-1").replayed?.should be_true
      clock.advance(2.hours)
      create(client, "hi", "k-1").replayed?.should be_false
      IdempotencySpec.notes.should eq(2)
      IdempotencySpec.keys.should eq(1)
      clock.advance(25.hours)
      Punch::Spec.db.write { |db| Punch::IdempotencyKeys.purge(db) }.should eq(1)
      IdempotencySpec.keys.should eq(0)
    end
  end

  it "makes a double submit of a form harmless with its hidden key" do
    IdempotencySpec.with_spec_db do
      client = IdempotencySpec.client.sign_in(1)
      page = client.visit(IdempotencySpec::Notes::CreatePage.href)
      key = page.html.find("input[name=_idempotency_key]").first["value"]
      key.size.should be >= 20
      form = {"body" => "hi", Punch::IdempotencyKeys::FIELD => key}
      first = client.submit(IdempotencySpec::Notes::Create.action, form: form)
      first.status.should eq(HTTP::Status::SEE_OTHER)
      client.submit(IdempotencySpec::Notes::Create.action, form: form).should be_replay_of(first)
      IdempotencySpec.notes.should eq(1)
      # A refused form is shown again with its key, and not stored.
      refused = client.submit(IdempotencySpec::Notes::Create.action, form: {"body" => "x", "explode" => "maybe", Punch::IdempotencyKeys::FIELD => "k-form"})
      refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      refused.html.find("input[name=_idempotency_key]").first["value"].should eq("k-form")
      IdempotencySpec.keys.should eq(1)
    end
  end

  it "keeps the answer across a restart between the two requests" do
    directory = File.tempname("idempotency-restart")
    Dir.mkdir(directory)
    path = File.join(directory, "primary.db")
    begin
      database = Punch::Database.open(path)
      Punch::Migrations::Schema.load(database, IdempotencySpec::SQL, "idempotency")
      database.write(&.exec("INSERT INTO users (id, name) VALUES (1, 'Ada')"))
      _, token = database.write { |db| Punch::Auth::Sessions.create(db, 1_i64, "password") }
      cookie = HTTP::Headers{"Cookie" => "#{Punch::Auth::COOKIE}=#{token.unwrap}", "Content-Type" => "application/json",
                             "Idempotency-Key" => "k-1"}
      request = ->(db : Punch::Database) do
        client = Punch::Spec::Client.new(Punch::Routing::Router.new(db), openapi: nil)
        client.post(IdempotencySpec::Notes::Create.path, body: %({"body": "hi"}), headers: cookie)
      end
      first = request.call(database)
      first.status.should eq(HTTP::Status::OK)
      database.close

      reopened = Punch::Database.open(path)
      again = request.call(reopened)
      again.should be_replay_of(first)
      reopened.read(&.query_one?("SELECT count(*) FROM notes", &.read(Int64))).should eq(1)
      reopened.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
