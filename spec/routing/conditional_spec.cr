require "../spec_helper"
require "../support/auth_schema"

module ConditionalSpec
  class_property revision = 1_i64

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
  struct Note
    include JSON::Serializable
    include Punch::HTTP::Versioned

    getter title : String
    getter revision : Int64

    def initialize(@title, @revision)
    end

    def version : Int64
      revision
    end
  end

  struct Plain
    include JSON::Serializable

    getter title = "plain"

    def initialize
    end
  end

  @[Punch::Status(404)]
  struct Missing
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Public]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      getter? missing : Bool = false
    end

    def call(input : Input, db : Punch::Reader, actor : Actor?) : Note | Missing
      input.missing? ? Missing.new : Note.new("Note", ConditionalSpec.revision)
    end
  end

  @[Punch::Public]
  struct Unversioned < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Plain
      Plain.new
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Touch < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Note
      Note.new("Note", ConditionalSpec.revision)
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end

  def self.headers(etag : String) : HTTP::Headers
    HTTP::Headers{"If-None-Match" => etag}
  end
end

describe "Conditional requests" do
  it "tags a versioned result and answers 304 without a body while the client's copy is current" do
    ConditionalSpec.revision = 1_i64
    client = ConditionalSpec.client
    first = client.get(ConditionalSpec::Show.path)
    first.status.should eq(HTTP::Status::OK)
    etag = first.headers["ETag"]
    etag.should match(/\AW\/"[A-Za-z0-9_-]{22}"\z/)
    first.headers["Cache-Control"].should eq("private, no-cache")

    again = client.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(etag))
    again.status.should eq(HTTP::Status::NOT_MODIFIED)
    again.body.should be_empty
    again.headers["ETag"].should eq(etag)
    again.headers["Content-Length"]?.should be_nil
    again.headers["Content-Type"]?.should be_nil

    ConditionalSpec.revision = 2_i64
    changed = client.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(etag))
    changed.status.should eq(HTTP::Status::OK)
    changed.headers["ETag"].should_not eq(etag)
    changed.json["revision"].should eq(2)
  end

  it "compares weakly, accepts a list and *, and puts the outcome on the wide event" do
    ConditionalSpec.revision = 1_i64
    client = ConditionalSpec.client
    etag = client.get(ConditionalSpec::Show.path).headers["ETag"]
    strong = etag.lchop("W/")
    client.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(strong)).status.should eq(HTTP::Status::NOT_MODIFIED)
    client.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(%(W/"other", #{etag}))).status.should eq(HTTP::Status::NOT_MODIFIED)
    client.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers("*")).status.should eq(HTTP::Status::NOT_MODIFIED)
    response = client.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(%(W/"other")))
    response.status.should eq(HTTP::Status::OK)
    not_modified = client.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(etag))
    not_modified.trace.root.attributes["punch.outcome"].should eq("not_modified")
  end

  it "gives each signed-in user their own tag" do
    AuthSchema.with_spec_db do
      ConditionalSpec.revision = 1_i64
      anonymous = ConditionalSpec.client.get(ConditionalSpec::Show.path).headers["ETag"]
      ada = ConditionalSpec.client.sign_in(1).get(ConditionalSpec::Show.path).headers["ETag"]
      grace = ConditionalSpec.client.sign_in(2)
      grace_tag = grace.get(ConditionalSpec::Show.path).headers["ETag"]
      [anonymous, ada, grace_tag].uniq.size.should eq(3)
      grace.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(ada)).status.should eq(HTTP::Status::OK)
      grace.get(ConditionalSpec::Show.path, headers: ConditionalSpec.headers(grace_tag)).status.should eq(HTTP::Status::NOT_MODIFIED)
    end
  end

  it "leaves other results, other members of the union, and Commands alone" do
    client = ConditionalSpec.client
    plain = client.get(ConditionalSpec::Unversioned.path, headers: ConditionalSpec.headers("*"))
    plain.status.should eq(HTTP::Status::OK)
    plain.headers["ETag"]?.should be_nil
    plain.headers["Cache-Control"].should eq("no-store")
    missing = client.get(ConditionalSpec::Show.path, query: {missing: "true"}, headers: ConditionalSpec.headers("*"))
    missing.status.should eq(HTTP::Status::NOT_FOUND)
    missing.headers["ETag"]?.should be_nil
    touched = client.post(ConditionalSpec::Touch.path, headers: ConditionalSpec.headers("*"))
    touched.status.should eq(HTTP::Status::OK)
    touched.headers["ETag"]?.should be_nil
  end

  it "documents the tag, the 304, and If-None-Match" do
    registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
    route = Punch::Routing.routes.find!(&.operation.== "ConditionalSpec::Show")
    entry = Punch::OpenAPI.operation(ConditionalSpec::Show, route, registry)
    entry["responses"]["304"]["headers"]["ETag"]["schema"].should eq(JSON.parse(%({"type": "string"})))
    entry["responses"]["304"]["content"]?.should be_nil
    entry["responses"]["200"]["headers"]["ETag"]?.should_not be_nil
    entry["parameters"].as_a.map { |parameter| {parameter["name"], parameter["in"]} }.should contain({"If-None-Match", "header"})
    plain = Punch::OpenAPI.operation(ConditionalSpec::Unversioned, Punch::Routing.routes.find!(&.operation.== "ConditionalSpec::Unversioned"), registry)
    plain["responses"]["304"]?.should be_nil
    plain["parameters"]?.should be_nil
  end

  it "tags by result type, user, version, and binary" do
    tag = Punch::HTTP::Conditional.etag("Note", 1_i64, nil)
    Punch::HTTP::Conditional.etag("Note", 1_i64, nil).should eq(tag)
    Punch::HTTP::Conditional.etag("Other", 1_i64, nil).should_not eq(tag)
    Punch::HTTP::Conditional.etag("Note", "1", 7_i64).should_not eq(tag)
    at = Time.utc(2026, 10, 9, 12, 0, 0, nanosecond: 1)
    Punch::HTTP::Conditional.etag("Note", at, nil).should_not eq(Punch::HTTP::Conditional.etag("Note", at - 1.nanosecond, nil))
  end
end
