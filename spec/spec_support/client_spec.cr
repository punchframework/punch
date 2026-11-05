require "../spec_helper"

module ClientSpec
  SCHEMA = <<-SQL
    CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT;
    SQL

  struct NoteID < Punch::TypedID
  end

  @[Punch::Status(200)]
  struct Note
    include JSON::Serializable

    getter id : NoteID
    getter body : String

    def initialize(@id, @body)
    end
  end

  @[Punch::Status(201)]
  struct Created
    include JSON::Serializable

    getter id : NoteID

    def initialize(@id)
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include JSON::Serializable

    def initialize
    end
  end

  module Notes
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter body : Punch::NonEmptyString
      end

      def call(input : Input, db : Punch::Writer) : Created
        result = db.exec("INSERT INTO notes (body) VALUES (?)", input.body.value)
        Created.new(NoteID.parse(result.last_insert_id).as(NoteID))
      end
    end

    @[Punch::Public]
    struct Show < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter note_id : NoteID
      end

      def call(input : Input, db : Punch::Reader) : Note | NotFound
        db.query_one?("SELECT id, body FROM notes WHERE id = ?", input.note_id.value) do |row|
          Note.new(NoteID.parse(row.read(Int64)).as(NoteID), row.read(String))
        end || NotFound.new
      end
    end
  end

  # What `punch openapi` derives for the two operations, written out.
  DOCUMENT = <<-JSON
    {"openapi": "3.2.0", "info": {"title": "notes", "version": "1.0.0"},
     "paths": {
       "/client_spec/notes": {"post": {"operationId": "client_spec.notes.create", "responses": {
         "201": {"description": "Created", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Created"}}}},
         "422": {"description": "Problem", "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/Punch.Problem"}}}},
         "default": {"description": "Problem", "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/Punch.Problem"}}}}}}},
       "/client_spec/notes/{note_id}": {"get": {"operationId": "client_spec.notes.show", "responses": {
         "200": {"description": "OK", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Note"}}}},
         "404": {"description": "Not Found", "content": {"application/problem+json": {"schema": {"allOf": [
           {"$ref": "#/components/schemas/Punch.Problem"}, {"properties": {"code": {"const": "not_found"}}}]}}}},
         "default": {"description": "Problem", "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/Punch.Problem"}}}}}}}},
     "components": {"schemas": {
       "Created": {"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}}, "required": ["id"]},
       "Note": {"type": "object", "properties": {"id": {"type": "integer", "minimum": 1}, "body": {"type": "string"}}, "required": ["id", "body"]},
       "Punch.Problem": {"type": "object", "properties": {"type": {"type": "string"}, "title": {"type": "string"},
         "status": {"type": "integer"}, "code": {"type": "string"}}, "required": ["type", "title", "status", "code"]}}}}
    JSON

  # Runs the block with this spec's schema as the example database's.
  def self.with_schema(&)
    path = File.tempname("client-spec", ".sql")
    File.write(path, SCHEMA)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    begin
      yield
    ensure
      Punch::Spec.schema = previous
      File.delete(path)
    end
  end
end

private def count : Int64?
  Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM notes", &.read(Int64)))
end

private def client(document : String = ClientSpec::DOCUMENT) : Punch::Spec::Client
  Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: document)
end

describe Punch::Spec::Client do
  it "runs requests in process, through the server's own pipeline, against this example's database" do
    ClientSpec.with_schema do
      client = client()
      created = client.post(ClientSpec::Notes::Create.path, json: {body: "first"})
      created.status.should eq(HTTP::Status::CREATED)
      id = created.json["id"].as_i64

      shown = client.get(ClientSpec::Notes::Show.path(note_id: ClientSpec::NoteID.parse(id).as(ClientSpec::NoteID)))
      shown.json.should eq(JSON.parse(%({"id": #{id}, "body": "first"})))
      shown.content_type.should eq("application/json")
      shown.headers["X-Content-Type-Options"].should eq("nosniff")
      shown.headers["X-Request-ID"].should eq(shown.trace.root.trace_id.to_s)
      shown.trace.should have_span("input")
      shown.trace.root["http.route"].should eq("/client_spec/notes/:note_id")
    end
  end

  it "gives every example a fresh database with the schema loaded" do
    ClientSpec.with_schema do
      count.should eq(0)
      Punch::Spec.db.write(&.exec("INSERT INTO notes (body) VALUES ('x')"))
      Punch::Spec.close_db # what runs after each example
      count.should eq(0)
    end
  end

  it "passes problems that keep the contract: rejections, missing records, unknown paths" do
    ClientSpec.with_schema do
      client = client()
      client.post(ClientSpec::Notes::Create.path, json: {body: " "}).status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      client.get("/client_spec/notes/99").json["code"].should eq("not_found")
      client.get("/nowhere").status.should eq(HTTP::Status::NOT_FOUND)
      client.delete("/client_spec/notes/1").status.should eq(HTTP::Status::METHOD_NOT_ALLOWED)
      client.head("/client_spec/notes/99").status.should eq(HTTP::Status::NOT_FOUND)
      client.get("/up").trace?.should be_nil
    end
  end

  it "fails the example when a response breaks the document" do
    ClientSpec.with_schema do
      # The document promises a title the code does not write.
      stricter = ClientSpec::DOCUMENT.sub(%("required": ["id", "body"]), %("required": ["id", "body", "title"]))
      client = client(stricter)
      id = client.post(ClientSpec::Notes::Create.path, json: {body: "x"}).json["id"].as_i64
      error = expect_raises(Spec::AssertionFailed) { client.get("/client_spec/notes/#{id}") }
      error.message.should eq(<<-TEXT)
        GET /client_spec/notes/#{id} answered 200, which breaks the OpenAPI document:
          body (root): "title" is missing (required)
        If the code is right, the document is stale: run 'punch openapi'.
        TEXT
      error.file.should eq(__FILE__)

      # A status the operation does not document, in a document without
      # `default` (Punch always writes one, for framework problems).
      document = JSON.parse(ClientSpec::DOCUMENT)
      responses = document["paths"]["/client_spec/notes/{note_id}"]["get"]["responses"].as_h
      responses.delete("404")
      responses.delete("default")
      error = expect_raises(Spec::AssertionFailed) { client(document.to_json).get("/client_spec/notes/99") }
      error.message.to_s.should contain("status 404 is not documented; it documents 200")
    end
  end

  it "checks media types, bodies that should be empty, and problems outside the document" do
    handler = Punch::HTTP::Handler.new do |context|
      case context.request.path
      when "/client_spec/notes"   then Punch::HTTP::Response.text(:created, "made")
      when "/client_spec/notes/1" then Punch::HTTP::Response.json(:ok, %({"id": 0, "body": 1}))
      else                             Punch::HTTP::Response.new(:not_found, %({"code": "gone"}), HTTP::Headers{"Content-Type" => "application/problem+json"})
      end
    end
    client = Punch::Spec::Client.new(handler, openapi: ClientSpec::DOCUMENT)
    expect_raises(Spec::AssertionFailed, "Content-Type text/plain is not documented; it documents application/json") do
      client.post("/client_spec/notes", body: "")
    end
    error = expect_raises(Spec::AssertionFailed) { client.get("/client_spec/notes/1") }
    error.message.to_s.should contain("body /id: 0 fails minimum 1.0 (minimum)\n  body /body: expected string, got integer (type)")
    error = expect_raises(Spec::AssertionFailed) { client.get("/elsewhere") }
    error.message.to_s.should contain(%(body (root): "type" is missing (required)))
  end

  it "sends query parameters and headers" do
    handler = Punch::HTTP::Handler.new do |context|
      Punch::HTTP::Response.text(:ok, "#{context.request.query} #{context.request.headers["Accept"]?}")
    end
    client = Punch::Spec::Client.new(handler, openapi: nil)
    client.get("/x", query: {page: 2, q: "a b"}, headers: HTTP::Headers{"Accept" => "text/plain"}).body.should eq("page=2&q=a+b text/plain")
  end

  it "raises an exception from the server with the request line, the original as its cause" do
    handler = Punch::HTTP::Handler.new { |_| raise KeyError.new("no such note") }
    client = Punch::Spec::Client.new(handler, openapi: nil)
    error = expect_raises(Punch::Spec::ServerError, "POST /x raised KeyError: no such note") { client.post("/x", json: {a: 1}) }
    error.cause.should be_a(KeyError)
    error.cause.try(&.backtrace?).should_not be_nil
  end

  it "keeps the exception on the 500 response of a client that does not raise" do
    handler = Punch::HTTP::Handler.new { |_| raise KeyError.new("no such note") }
    client = Punch::Spec::Client.new(handler, openapi: nil, raise_errors: false)
    response = client.get("/x")
    response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
    response.exception.try(&.message).should eq("no such note")
    ok = Punch::Spec::Client.new(Punch::HTTP::Handler.new { |_| Punch::HTTP::Response.text(:ok, "fine") }, openapi: nil)
    ok.get("/x").exception.should be_nil
  end
end
