require "../spec_helper"

# Unique violations returned by Commands: answered like a rejected input, as
# Problem Details and as field errors on forms, and the Command's writes
# roll back.
module ViolationsSpec
  SQL = <<-SQL + Punch::Auth::Schema.sql
    CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
    CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE) STRICT;
    CREATE TABLE events (id INTEGER PRIMARY KEY, what TEXT NOT NULL) STRICT;
    CREATE TRIGGER tags_kept BEFORE DELETE ON tags BEGIN SELECT RAISE(ABORT, 'punch:tag_kept'); END;

    SQL

  # What `punch db:generate` writes for `tags.name`.
  struct NameTaken
    include Punch::Database::Violation

    CONSTRAINT = "tags.name"
    FIELD      = "name"
    MESSAGE    = "UNIQUE constraint failed: tags.name"
  end

  # What `punch db:generate` writes for `Punch.violation "tag_kept", …, status: 409`.
  @[Punch::Status(409)]
  struct Kept
    include Punch::Database::Refusal

    CONSTRAINT   = "tags: trigger tags_kept"
    MESSAGE      = "punch:tag_kept"
    PROBLEM_CODE = "tag_kept"
  end

  # Like a generated delete.
  def self.delete_tag(db : Punch::Writer, name : String) : Bool | Kept
    db.exec("DELETE FROM tags WHERE name = ?", name).changes > 0
  rescue ex : Punch::Database::ConstraintError
    ex.detail == Kept::MESSAGE ? Kept.new : raise ex
  end

  # Like a generated insert.
  def self.insert_tag(db : Punch::Writer, name : String) : Int64 | NameTaken
    db.query_one?("INSERT INTO tags (name) VALUES (?) RETURNING id", name) { |row| row.read(Int64) } || raise "no row"
  rescue ex : Punch::Database::ConstraintError
    ex.detail == NameTaken::MESSAGE ? NameTaken.new : raise ex
  end

  def self.events : Array(String)
    Punch::Spec.db.read(&.query_all("SELECT what FROM events ORDER BY id") { |row| row.read(String) })
  end

  module Tags
    @[Punch::Status(201)]
    struct Created
      include JSON::Serializable

      getter id : Int64

      def initialize(@id : Int64)
      end
    end

    # Records an event before it writes, so a refusal shows whether the
    # event was rolled back.
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter name : Punch::NonEmptyString
      end

      def call(input : Input, db : Punch::Writer) : Created | NameTaken
        db.exec("INSERT INTO events (what) VALUES (?)", "create #{input.name}")

        case id = ViolationsSpec.insert_tag(db, input.name.value)
        in Int64     then Created.new(id)
        in NameTaken then id
        end
      end
    end

    # Its input calls the name `title`, so it maps the violation.
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Rename < Punch::Command
      struct Input
        include Punch::Input

        getter title : Punch::NonEmptyString
      end

      def call(input : Input, db : Punch::Writer) : Created | Punch::Rejection
        case id = ViolationsSpec.insert_tag(db, input.title.value)
        in Int64     then Created.new(id)
        in NameTaken then id.rejection("title")
        end
      end
    end

    @[Punch::Status(204)]
    struct Deleted
      include JSON::Serializable

      def initialize
      end
    end

    # Records an event, then deletes, which the trigger refuses.
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Delete < Punch::Command
      struct Input
        include Punch::Input

        getter name : Punch::NonEmptyString
      end

      def call(input : Input, db : Punch::Writer) : Deleted | ViolationsSpec::Kept
        db.exec("INSERT INTO events (what) VALUES (?)", "delete #{input.name}")

        case deleted = ViolationsSpec.delete_tag(db, input.name.value)
        in Bool                 then Deleted.new
        in ViolationsSpec::Kept then deleted
        end
      end
    end

    @[Punch::Status(409)]
    struct Busy
      include JSON::Serializable

      def initialize
      end
    end

    # Signs in, then refuses: the session must not survive.
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Join < Punch::Command
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : Busy
        auth.sign_in(1_i64, method: "password")
        Busy.new
      end
    end

    struct Form
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.document("New tag") do
          v.form(Create.action) do |form|
            form.field :name
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

      def call(input : Input, db : Punch::Reader) : Form
        Form.new
      end
    end
  end

  def self.with_db(&)
    path = File.tempname("violations-spec", ".sql")
    File.write(path, SQL)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    begin
      Punch::Spec.db.write(&.exec("INSERT INTO users (id, name) VALUES (1, 'Ada')"))
      yield Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
    ensure
      Punch::Spec.schema = previous
      File.delete(path)
    end
  end
end

private def name(value : String) : Punch::NonEmptyString
  Punch::NonEmptyString.parse(value).as(Punch::NonEmptyString)
end

describe "violations returned by Commands" do
  it "answer 422 like a rejected input, and roll the Command's writes back" do
    ViolationsSpec.with_db do |client|
      client.post(ViolationsSpec::Tags::Create.path, json: {name: "red"}).status.should eq(HTTP::Status::CREATED)
      response = client.post(ViolationsSpec::Tags::Create.path, json: {name: "red"})
      response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      response.headers["Content-Type"].should eq("application/problem+json")
      response.json["code"].should eq("invalid_input")
      response.json["errors"].should eq(JSON.parse(%([{"path": ["name"], "code": "taken", "params": {}, "message": "Is already taken."}])))
      response.trace.try(&.root.attributes["punch.violation"]?).should eq("tags.name")
      response.trace.try(&.root.attributes["punch.outcome"]?).should eq("invalid_input")
      ViolationsSpec.events.should eq(["create red"])
    end
  end

  it "show the form again with the error at the field" do
    ViolationsSpec.with_db do |client|
      client.submit(ViolationsSpec::Tags::Create.action, {name: name("blue")}).status.should eq(HTTP::Status::SEE_OTHER)
      page = client.submit(ViolationsSpec::Tags::Create.action, {name: name("blue")})
      page.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      page.should have_field_error("name", "taken")
      page.should have_element("input[name=name][value=blue]")
      ViolationsSpec.events.should eq(["create blue"])
    end
  end

  it "can be returned as a rejection at another path" do
    ViolationsSpec.with_db do |client|
      client.post(ViolationsSpec::Tags::Rename.path, json: {title: "green"})
      response = client.post(ViolationsSpec::Tags::Rename.path, json: {title: "green"})
      response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      response.json["errors"][0]["path"].should eq(JSON.parse(%(["title"])))
    end
  end

  it "leave a failed Command without its sign-in" do
    ViolationsSpec.with_db do |client|
      response = client.post(ViolationsSpec::Tags::Join.path)
      response.status.should eq(HTTP::Status::CONFLICT)
      response.headers["Set-Cookie"]?.should be_nil
      Punch::Spec.db.read { |db| Punch::Auth::Sessions.list(db) }.should be_empty
    end
  end

  it "answer a trigger's 409 rule as a problem with its code, and roll the Command's writes back" do
    ViolationsSpec.with_db do |client|
      client.post(ViolationsSpec::Tags::Create.path, json: {name: "red"}).status.should eq(HTTP::Status::CREATED)
      response = client.post(ViolationsSpec::Tags::Delete.path, json: {name: "red"})
      response.status.should eq(HTTP::Status::CONFLICT)
      response.json["code"].should eq("tag_kept")
      response.trace.try(&.root.attributes["punch.outcome"]?).should eq("tag_kept")
      ViolationsSpec.events.should eq(["create red"])
      registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
      route = Punch::Routing.routes.find!(&.operation.==("ViolationsSpec::Tags::Delete"))
      Punch::OpenAPI.operation(ViolationsSpec::Tags::Delete, route, registry)["responses"]["409"].to_json.should contain(%("const":"tag_kept"))
    end
  end

  it "are documented as the input's 422" do
    registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
    entry = ->(name : String) { Punch::Routing.routes.find!(&.operation.==(name)) }
    validation = JSON.parse(%({"$ref": "#/components/schemas/Punch.ValidationProblem"}))
    create = Punch::OpenAPI.operation(ViolationsSpec::Tags::Create, entry.call("ViolationsSpec::Tags::Create"), registry)
    create["responses"]["422"]["content"]["application/problem+json"]["schema"].should eq(validation)
    rename = Punch::OpenAPI.operation(ViolationsSpec::Tags::Rename, entry.call("ViolationsSpec::Tags::Rename"), registry)
    rename["responses"]["422"]["content"]["application/problem+json"]["schema"].should eq(validation)
  end
end
