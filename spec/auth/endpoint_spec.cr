require "../spec_helper"
require "../support/auth_schema"

module AuthSpec
  struct UserID < Punch::TypedID
  end

  struct Actor
    include Punch::Auth::Actor

    getter id : UserID
    getter name : String
    getter principal : Punch::Auth::Principal

    def initialize(@id, @name, @principal)
    end

    # A user called "gone" counts as deleted.
    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      db.query_one?("SELECT name FROM users WHERE id = ? AND name != 'gone'", principal.user_id) do |row|
        new(principal.user_id(UserID), row.read(String), principal)
      end
    end
  end

  struct Named
    include JSON::Serializable

    getter name : String
    getter via : String

    def initialize(@name, @via)
    end
  end

  struct SignedIn
    include JSON::Serializable

    getter session_id : Int64

    def initialize(@session_id)
    end
  end

  @[Punch::Public]
  struct Me < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, actor : Actor) : Named
      Named.new(actor.name, actor.principal.via.is_a?(Punch::Auth::Session) ? "session" : "token")
    end
  end

  @[Punch::Public]
  struct Greeting < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, actor : Actor?) : Named
      Named.new(actor.try(&.name) || "stranger", actor ? "someone" : "nobody")
    end
  end

  @[Punch::Public]
  struct Rename < Punch::Command
    struct Input
      include Punch::Input

      getter name : String
    end

    def call(input : Input, db : Punch::Writer, actor : Actor) : Named
      db.exec("UPDATE users SET name = ? WHERE id = ?", input.name, actor.id.value)
      Named.new(input.name, "writer")
    end
  end

  # Stands in for a real sign-in: the app checks a password first.
  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input

      getter user_id : UserID
      getter? fail_after : Bool = false
    end

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : SignedIn
      session = auth.sign_in(input.user_id, method: "password").as(Punch::Auth::Session)
      raise "failed after signing in" if input.fail_after?
      SignedIn.new(session.id)
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct SignOut < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : Nil
      auth.sign_out
    end
  end

  # A change of privilege: the session gets a new ID.
  @[Punch::Public]
  struct Elevate < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Actor, auth : Punch::Auth::Authentication) : SignedIn
      SignedIn.new((auth.renew(method: "password+totp") || raise "no session").id)
    end
  end

  def self.client(raise_errors : Bool = true) : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil, raise_errors: raise_errors)
  end

  def self.sessions : Int64
    Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM punch_sessions", &.read(Int64))) || 0_i64
  end

  def self.cookie_attributes(response : Punch::Spec::Response) : Array(String)
    response.headers["Set-Cookie"].split("; ")
  end
end

describe "Authentication in endpoints" do
  it "answers 401 with a challenge when an operation needs an actor, without opening a transaction" do
    AuthSchema.with_spec_db do
      response = AuthSpec.client.get(AuthSpec::Me.path)
      response.status.should eq(HTTP::Status::UNAUTHORIZED)
      response.json["code"].should eq("unauthenticated")
      response.headers["WWW-Authenticate"].should eq("Bearer")
      response.trace.spans.none?(&.name.ends_with?(" read")).should be_true
      response.trace.root["punch.outcome"].should eq("unauthenticated")
    end
  end

  it "passes the actor of a session cookie, and puts the user on the wide event" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client.sign_in(AuthSpec::UserID.parse(1).as(AuthSpec::UserID))
      response = client.get(AuthSpec::Me.path)
      response.json.should eq(JSON.parse(%({"name": "Ada", "via": "session"})))
      response.trace.root["user.id"].should eq(1)
      response.trace.root["punch.auth"].should eq("session")
      response.trace.should have_span("Punch::Auth::Sessions.find")
      response.headers["Set-Cookie"]?.should be_nil
    end
  end

  it "passes the actor of a bearer token, ignores the cookie beside it, and refuses a bad token outright" do
    AuthSchema.with_spec_db do
      token = Punch::Spec.api_token(2)
      client = AuthSpec.client.sign_in(1)
      response = client.get(AuthSpec::Me.path, headers: Punch::Spec.bearer(token))
      response.json.should eq(JSON.parse(%({"name": "Grace", "via": "token"})))
      response.trace.root["punch.auth"].should eq("token")

      {"Bearer #{token.sub(-1, token[-1] == 'a' ? 'b' : 'a')}", "Bearer", "Basic dXNlcjpwYXNz", "Bearer #{Punch::Auth::APITokens.generate("punch")}"}.each do |header|
        bad = client.get(AuthSpec::Me.path, headers: HTTP::Headers{"Authorization" => header})
        bad.status.should eq(HTTP::Status::UNAUTHORIZED)
        bad.headers["WWW-Authenticate"].should eq(%(Bearer error="invalid_token"))
        # Where an actor is optional, a token that does not work is still refused.
        client.get(AuthSpec::Greeting.path, headers: HTTP::Headers{"Authorization" => header}).status.should eq(HTTP::Status::UNAUTHORIZED)
      end
    end
  end

  it "runs an operation with an optional actor for anyone" do
    AuthSchema.with_spec_db do
      AuthSpec.client.get(AuthSpec::Greeting.path).json["name"].should eq("stranger")
      AuthSpec.client.sign_in(2).get(AuthSpec::Greeting.path).json["name"].should eq("Grace")
    end
  end

  it "clears a cookie that names no live session" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client
      client.cookies[Punch::Auth::COOKIE] = Punch::Auth::Token.generate
      response = client.get(AuthSpec::Greeting.path)
      response.json["name"].should eq("stranger")
      response.headers["Set-Cookie"].should eq("__Host-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax")
      response.trace.root["punch.auth"].should eq("expired")
      client.cookies.should be_empty

      client.cookies[Punch::Auth::COOKIE] = "forged"
      required = client.get(AuthSpec::Me.path)
      required.status.should eq(HTTP::Status::UNAUTHORIZED)
      required.headers["Set-Cookie"].should contain("Max-Age=0")
    end
  end

  it "treats a principal whose user the app cannot load as nobody" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client.sign_in(1)
      Punch::Spec.db.write(&.exec("UPDATE users SET name = 'gone' WHERE id = 1"))
      client.get(AuthSpec::Me.path).status.should eq(HTTP::Status::UNAUTHORIZED)
      client.get(AuthSpec::Greeting.path).json["name"].should eq("stranger")
    end
  end

  it "loads the actor inside a Command's write transaction" do
    AuthSchema.with_spec_db do
      response = AuthSpec.client.sign_in(1).post(AuthSpec::Rename.path, json: {name: "Ada L."})
      response.json["name"].should eq("Ada L.")
      write = response.trace.spans.find!(&.name.ends_with?(" write"))
      find = response.trace.spans.find!(&.name.== "Punch::Auth::Sessions.find")
      find.parent_id.should eq(write.span_id)
    end
  end

  it "signs in with a new session and a __Host- cookie, ending the session the request came with" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client.sign_in(2)
      response = client.post(AuthSpec::SignIn.path, json: {user_id: 1}, headers: HTTP::Headers{"User-Agent" => "Spec browser"})
      response.status.should eq(HTTP::Status::OK)
      attributes = AuthSpec.cookie_attributes(response)
      attributes[0].should match(/\A__Host-session=[0-9A-Za-z]{43}\z/)
      attributes[1..].should eq(["Path=/", "Max-Age=#{30.days.total_seconds.to_i}", "Secure", "HttpOnly", "SameSite=Lax"])
      AuthSpec.sessions.should eq(1)
      session = Punch::Spec.db.read { |db| Punch::Auth::Sessions.list(db) }.first
      session.id.should eq(response.json["session_id"].as_i64)
      session.user_agent.should eq("Spec browser")
      session.ip.should eq("127.0.0.1")

      client.get(AuthSpec::Me.path).json["name"].should eq("Ada")
    end
  end

  it "sets no cookie and keeps no session when the Command fails after signing in" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client(raise_errors: false)
      response = client.post(AuthSpec::SignIn.path, json: {user_id: 1, fail_after: true})
      response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
      response.headers["Set-Cookie"]?.should be_nil
      AuthSpec.sessions.should eq(0)
      client.cookies.should be_empty
    end
  end

  it "signs out: the row is gone and the cookie cleared" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client.sign_in(1)
      response = client.post(AuthSpec::SignOut.path)
      response.status.should eq(HTTP::Status::NO_CONTENT)
      response.headers["Set-Cookie"].should contain("Max-Age=0")
      AuthSpec.sessions.should eq(0)
      client.get(AuthSpec::Me.path).status.should eq(HTTP::Status::UNAUTHORIZED)
    end
  end

  it "renews the session ID on a change of privilege; the old cookie stops working" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client.sign_in(1)
      old = client.cookies[Punch::Auth::COOKIE]
      response = client.post(AuthSpec::Elevate.path)
      client.cookies[Punch::Auth::COOKIE].should_not eq(old)
      Punch::Spec.db.read { |db| Punch::Auth::Sessions.list(db) }.first.method.should eq("password+totp")
      client.get(AuthSpec::Me.path).status.should eq(HTTP::Status::OK)
      AuthSpec.client.get(AuthSpec::Me.path, headers: HTTP::Headers{"Cookie" => "#{Punch::Auth::COOKIE}=#{old}"}).status.should eq(HTTP::Status::UNAUTHORIZED)
      response.json["session_id"].should eq(Punch::Spec.db.read { |db| Punch::Auth::Sessions.list(db) }.first.id)
    end
  end

  it "writes the last-seen time only when it is due, after a Query's read" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client.sign_in(1, now: Time.utc - 10.minutes)
      first = client.get(AuthSpec::Me.path)
      first.trace.should have_span("Punch::Auth::Sessions.touch")
      touch = first.trace.spans.find!(&.name.== "Punch::Auth::Sessions.touch")
      write = first.trace.spans.find!(&.name.ends_with?(" write"))
      touch.parent_id.should eq(write.span_id)
      seen = Punch::Spec.db.read { |db| Punch::Auth::Sessions.list(db) }.first.last_seen_at
      (Time.utc - seen).should be < 1.minute

      second = client.get(AuthSpec::Me.path)
      second.trace.spans.none?(&.name.== "Punch::Auth::Sessions.touch").should be_true
      second.trace.spans.none?(&.name.ends_with?(" write")).should be_true
    end
  end

  it "records when an API token was last used" do
    AuthSchema.with_spec_db do
      token = Punch::Spec.api_token(1)
      AuthSpec.client.get(AuthSpec::Me.path, headers: Punch::Spec.bearer(token))
      Punch::Spec.db.read { |db| Punch::Auth::APITokens.list(db) }.first.last_used_at.should_not be_nil
    end
  end

  it "refuses a cross-site Command before anything runs, and lets a bearer-token request through" do
    AuthSchema.with_spec_db do
      client = AuthSpec.client.sign_in(1)
      forged = client.post(AuthSpec::Rename.path, json: {name: "Mallory"}, headers: HTTP::Headers{"Sec-Fetch-Site" => "cross-site"})
      forged.status.should eq(HTTP::Status::FORBIDDEN)
      forged.json["code"].should eq("cross_origin_request")
      forged.trace.spans.none?(&.name.ends_with?(" write")).should be_true
      Punch::Spec.db.read(&.query_one?("SELECT name FROM users WHERE id = 1", &.read(String))).should eq("Ada")

      same = client.post(AuthSpec::Rename.path, json: {name: "Ada L."}, headers: HTTP::Headers{"Sec-Fetch-Site" => "same-origin"})
      same.status.should eq(HTTP::Status::OK)
      token = Punch::Spec.api_token(1)
      headers = Punch::Spec.bearer(token).tap { |all| all["Sec-Fetch-Site"] = "cross-site" }
      AuthSpec.client.post(AuthSpec::Rename.path, json: {name: "Ada"}, headers: headers).status.should eq(HTTP::Status::OK)
    end
  end

  it "documents who may call: both schemes where an actor is needed, also nobody where it is optional, and 401" do
    registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
    entry = ->(operation : String) { Punch::Routing.routes.find!(&.operation.== operation) }
    me = Punch::OpenAPI.operation(AuthSpec::Me, entry.call("AuthSpec::Me"), registry)
    me["security"].should eq(JSON.parse(%([{"session": []}, {"bearer": []}])))
    me["responses"]["401"]["content"]["application/problem+json"]["schema"]["allOf"][1].should eq(JSON.parse(%({"properties": {"code": {"const": "unauthenticated"}}})))
    greeting = Punch::OpenAPI.operation(AuthSpec::Greeting, entry.call("AuthSpec::Greeting"), registry)
    greeting["security"].should eq(JSON.parse(%([{"session": []}, {"bearer": []}, {}])))
    sign_in = Punch::OpenAPI.operation(AuthSpec::SignIn, entry.call("AuthSpec::SignIn"), registry)
    sign_in["security"]?.should be_nil
    sign_in["responses"]["401"]?.should be_nil
  end
end
