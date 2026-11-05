require "../spec_helper"
require "../support/auth_schema"

module PasswordsSpec
  struct UserID < Punch::TypedID
  end

  struct Actor
    include Punch::Auth::Actor

    getter id : UserID
    getter principal : Punch::Auth::Principal

    def initialize(@id, @principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal.user_id(UserID), principal)
    end
  end

  struct SignedIn
    include JSON::Serializable

    getter user_id : UserID

    def initialize(@user_id)
    end
  end

  class_property hashed_inside = [] of Bool

  module Accounts
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct SignUp < Punch::Command
      struct Input
        include Punch::Input

        getter name : String
        getter email : Punch::Email
        getter password : Punch::Auth::NewPassword
      end

      def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : SignedIn | Punch::Auth::EmailIdentities::EmailTaken
        PasswordsSpec.hashed_inside << input.password.hashed?
        id = db.query_one?("INSERT INTO users (name) VALUES (?) RETURNING id", input.name, &.read(Int64)) || raise "no user"
        user_id = UserID.parse(id).as(UserID)
        identity = Punch::Auth::EmailIdentities.add(db, user_id, input.email)
        return identity if identity.is_a?(Punch::Auth::EmailIdentities::EmailTaken)

        Punch::Auth::Passwords.set(db, user_id, input.password.hashed)
        auth.sign_in(user_id, method: "password")
        SignedIn.new(user_id)
      end
    end

    @[Punch::RateLimit(5, per: 1.minute, by: :email)]
    @[Punch::Public]
    struct SignIn < Punch::Command
      struct Input
        include Punch::Input

        getter email : Punch::Email
        getter password : Punch::Auth::Password
      end

      def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, password : Punch::Auth::PasswordCheck,
               events : Punch::Events(Punch::Auth::SignInSucceeded | Punch::Auth::SignInFailed)) : SignedIn | Punch::Auth::InvalidCredentials
        user_id = password.confirm(db, UserID) || return Punch::Auth::InvalidCredentials.new
        session = auth.sign_in(user_id, method: "password").as(Punch::Auth::Session)
        events.publish(Punch::Auth::SignInSucceeded.new(user_id.value, session.id, "password"))
        SignedIn.new(user_id)
      end
    end

    struct PasswordChanged
      include JSON::Serializable

      def initialize
      end
    end

    # Changes the signed-in user's password, given the current one.
    @[Punch::RateLimit(3, per: 1.minute, by: :actor)]
    @[Punch::Public]
    struct ChangePassword < Punch::Command
      struct Input
        include Punch::Input

        getter current_password : Punch::Auth::Password
        getter password : Punch::Auth::NewPassword
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, password : Punch::Auth::OwnPasswordCheck) : PasswordChanged | Punch::Auth::InvalidCredentials
        return Punch::Auth::InvalidCredentials.new unless password.confirm(db)

        Punch::Auth::Passwords.set(db, actor.id, input.password.hashed)
        PasswordChanged.new
      end
    end

    @[Punch::Public]
    struct SignInPage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader) : SignInForm
        SignInForm.new
      end

      def self.redirect(result : SignedIn) : Punch::Href
        SignInPage.href
      end
    end

    @[Punch::Public]
    struct SignUpPage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader) : SignUpForm
        SignUpForm.new
      end

      def self.redirect(result : SignedIn) : Punch::Href
        SignInPage.href
      end
    end

    struct SignInForm
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.document("Sign in") do
          v.form(SignIn.action) do |form|
            form.field :email
            form.field :password
            form.submit "Sign in"
          end
        end
      end
    end

    struct SignUpForm
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.document("Sign up") do
          v.form(SignUp.action) do |form|
            form.field :name
            form.field :email
            form.field :password
            form.submit "Sign up"
          end
        end
      end
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end

  def self.email(text : String) : Punch::Email
    Punch::Email.parse(text).as(Punch::Email)
  end

  def self.password(text : String) : Punch::Auth::Password
    Punch::Auth::Password.parse(text).as(Punch::Auth::Password)
  end

  def self.stored(user_id : Int64) : String
    Punch::Spec.db.read(&.query_one?("SELECT hash FROM punch_passwords WHERE user_id = ?", user_id, &.read(String))) || raise "no password"
  end

  # Occupies every worker of *hasher* and its one place in the queue,
  # until *gate* lets each job go.
  def self.fill(hasher : Punch::Auth::Passwords::Hasher, gate : Channel(Nil), results : Channel(Bool)) : Nil
    raise "fill expects a queue of 1" unless hasher.capacity == 1
    started = Channel(Nil).new(hasher.workers + 1)
    # One at a time: a job sent while the one before still sits in the
    # queue would find it full.
    hasher.workers.times do
      spawn { results.send(hasher.run { started.send(nil); gate.receive }) }
      started.receive
    end
    # This one waits in the queue: no worker is free to take it.
    spawn { results.send(hasher.run { gate.receive }) }
    until hasher.queued == 1
      Fiber.yield
    end
  end

  def self.with_hasher(hasher : Punch::Auth::Passwords::Hasher, &)
    previous = Punch::Auth::Passwords.hasher
    Punch::Auth::Passwords.hasher = hasher
    begin
      yield
    ensure
      Punch::Auth::Passwords.hasher = previous
    end
  end
end

PASSWORD = "correct horse battery"

describe Punch::Auth::Passwords do
  it "hashes in the versioned PHC format and verifies in constant time" do
    hash = Punch::Auth::Passwords.hash_now(PASSWORD, 1_000).text
    hash.should match(/\A\$pbkdf2-sha256\$i=1000\$[A-Za-z0-9+\/]{22}\$[A-Za-z0-9+\/]{43}\z/)
    Punch::Auth::Passwords.verify_now(PASSWORD, hash).should eq(Punch::Auth::Passwords::Verdict::Valid)
    Punch::Auth::Passwords.verify_now("correct horse batterY", hash).should eq(Punch::Auth::Passwords::Verdict::Invalid)
    Punch::Auth::Passwords.hash_now(PASSWORD, 1_000).text.should_not eq(hash)
    Punch::Auth::Passwords.parameters(hash).should eq("pbkdf2-sha256 i=1000")
  end

  it "reads a hash OpenSSL computed" do
    # openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt pass:"correct horse battery"
    #   -kdfopt salt:saltSALTsaltSALT -kdfopt iter:1000 PBKDF2
    stored = "$pbkdf2-sha256$i=1000$c2FsdFNBTFRzYWx0U0FMVA$vNe/qnobzAXyZZgzShY6O4Nt0SaW2sdUN/qkkFuJxaQ"
    Punch::Auth::Passwords.verify_now(PASSWORD, stored).should eq(Punch::Auth::Passwords::Verdict::Valid)
  end

  it "asks for a rehash of a hash with fewer iterations than configured" do
    old = Punch::Auth::Passwords.hash_now(PASSWORD, 500).text
    Punch::Auth::Passwords.verify_now(PASSWORD, old).should eq(Punch::Auth::Passwords::Verdict::ValidNeedsRehash)
    Punch::Auth::Passwords.current?(old).should be_false
    Punch::Auth::Passwords.current?(Punch::Auth::Passwords.hash_now(PASSWORD).text).should be_true
  end

  it "treats malformed and foreign hashes as Invalid" do
    good = Punch::Auth::Passwords.hash_now(PASSWORD, 1_000).text
    salt, digest = good.split('$')[3], good.split('$')[4]
    [
      "", "$", "plain", "$2b$12$abcdefghijklmnopqrstuuJmZ7cZr2gG3L9nH7zT0XbqZf0wVvW5m",
      "$argon2id$v=19$m=65536,t=3,p=4$#{salt}$#{digest}",
      "$pbkdf2-sha256$i=0$#{salt}$#{digest}", "$pbkdf2-sha256$i=999999999$#{salt}$#{digest}",
      "$pbkdf2-sha256$i=1000$#{salt}$#{digest[0..-3]}", "$pbkdf2-sha256$i=1000$#{salt}$#{digest}$",
      "$pbkdf2-sha256$i=1000$%%%$#{digest}", "$pbkdf2-sha256$1000$#{salt}$#{digest}",
      "$pbkdf2-sha256$i=1000$#{salt[0..-3]}$#{digest}",
    ].each do |stored|
      Punch::Auth::Passwords.verify_now(PASSWORD, stored).should eq(Punch::Auth::Passwords::Verdict::Invalid)
    end
  end

  it "refuses fewer iterations than OWASP's minimum outside specs" do
    expect_raises(ArgumentError, /at least 600000/) { Punch::Auth::Passwords::Config.new(iterations: 100_000) }
    expect_raises(ArgumentError, /threads/) { Punch::Auth::Passwords::Config.new(threads: 0) }
    expect_raises(ArgumentError, /queue/) { Punch::Auth::Passwords::Config.new(queue: 0) }
    Punch::Auth::Passwords::Config.new.iterations.should eq(600_000)
  end

  it "answers Busy at once when the hasher's queue is full" do
    hasher = Punch::Auth::Passwords::Hasher.new(1, 1)
    gate = Channel(Nil).new
    results = Channel(Bool).new(8)
    PasswordsSpec.fill(hasher, gate, results)
    hasher.hash(PASSWORD).should be_a(Punch::Auth::PasswordsBusy)
    hasher.verify(PASSWORD, "").should be_a(Punch::Auth::PasswordsBusy)
    (hasher.workers + 1).times { gate.send(nil) }
    (hasher.workers + 1).times { results.receive.should be_true }
    hasher.verify(PASSWORD, Punch::Auth::Passwords.hash_now(PASSWORD).text).should eq(Punch::Auth::Passwords::Verdict::Valid)
  end

  it "verifies from many fibers on its threads" do
    hasher = Punch::Auth::Passwords::Hasher.new(2, 64)
    stored = Punch::Auth::Passwords.hash_now(PASSWORD).text
    done = Channel(Punch::Auth::Passwords::Verdict | Punch::Auth::PasswordsBusy).new(32)
    32.times { |index| spawn { done.send(hasher.verify(index.even? ? PASSWORD : "wrong", stored)) } }
    verdicts = Array.new(32) { done.receive }
    verdicts.count(Punch::Auth::Passwords::Verdict::Valid).should eq(16)
    verdicts.count(Punch::Auth::Passwords::Verdict::Invalid).should eq(16)
  end

  it "stores one password per user and counts the parameters in use" do
    AuthSchema.with_spec_db do
      Punch::Spec.db.write do |db|
        Punch::Auth::Passwords.set?(db, 1).should be_false
        Punch::Auth::Passwords.set(db, 1, Punch::Auth::Passwords.hash_now(PASSWORD, 500))
        Punch::Auth::Passwords.set(db, 1, Punch::Auth::Passwords.hash_now(PASSWORD))
        Punch::Auth::Passwords.set(db, 2, Punch::Auth::Passwords.hash_now(PASSWORD, 500))
        Punch::Auth::Passwords.set?(db, 1).should be_true
        Punch::Auth::Passwords.census(db).should eq({"pbkdf2-sha256 i=1000" => 1, "pbkdf2-sha256 i=500" => 1})
        db.exec("DELETE FROM users WHERE id = 2")
        Punch::Auth::Passwords.census(db).size.should eq(1)
      end
    end
  end
end

describe Punch::Auth::Password do
  it "normalizes to NFKC and keeps surrounding spaces" do
    composed = Punch::Auth::Password.parse("café ").as(Punch::Auth::Password)
    decomposed = Punch::Auth::Password.parse("café ").as(Punch::Auth::Password)
    composed.unwrap.should eq("café ")
    (composed == decomposed).should be_true
    Punch::Auth::Password.parse("ﬁ").as(Punch::Auth::Password).unwrap.should eq("fi")
  end

  it "refuses blank, control characters, broken encoding, and too long" do
    Punch::Auth::Password.parse("   ").should eq(Punch::Invalid.new("blank"))
    Punch::Auth::Password.parse("a\u0000b").should eq(Punch::Invalid.new("invalid_characters"))
    Punch::Auth::Password.parse(String.new(Bytes[0xff, 0xfe])).should eq(Punch::Invalid.new("invalid_encoding"))
    Punch::Auth::Password.parse("a" * 256).should be_a(Punch::Auth::Password)
    Punch::Auth::Password.parse("a" * 257).should eq(Punch::Invalid.new("too_long", max: 256))
    # Four bytes a character at most, so 256 characters stay within 1,024 bytes.
    Punch::Auth::Password.parse("😀" * 256).should be_a(Punch::Auth::Password)
    Punch::Auth::Password.parse("😀" * 257).should eq(Punch::Invalid.new("too_long", max: 256))
  end

  it "never prints" do
    password = Punch::Auth::Password.parse("hunter2hunter2").as(Punch::Auth::Password)
    password.to_s.should eq("[REDACTED]")
    password.inspect.should_not contain("hunter2")
    "#{password}".should_not contain("hunter2")
  end

  it "asks a new password for 12 characters" do
    Punch::Auth::NewPassword.parse("short pass!").should eq(Punch::Invalid.new("too_short", min: 12))
    password = Punch::Auth::NewPassword.parse(PASSWORD).as(Punch::Auth::NewPassword)
    password.hashed?.should be_false
    Punch::Auth::Passwords.verify_now(PASSWORD, password.hashed.text).valid?.should be_true
    password.hashed.should eq(password.hashed)
    password.inspect.should_not contain("horse")
  end

  it "has a JSON Schema with the password format and lengths" do
    registry = Punch::JSONSchema::Registry.new
    registry.schema(Punch::Auth::Password).should eq(JSON.parse(%({"type": "string", "format": "password", "maxLength": 256})))
    registry.schema(Punch::Auth::NewPassword).should eq(JSON.parse(%({"type": "string", "format": "password", "minLength": 12, "maxLength": 256})))
  end
end

describe Punch::Auth::EmailIdentities do
  it "adds an address to one user only, and finds and verifies it" do
    AuthSchema.with_spec_db do
      Punch::Spec.db.write do |db|
        ada = Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("Ada@Example.org")).as(Punch::Auth::EmailIdentity)
        ada.email.value.should eq("ada@example.org")
        ada.verified?.should be_false
        Punch::Auth::EmailIdentities.add(db, 2, PasswordsSpec.email("ada@example.org")).should be_a(Punch::Auth::EmailIdentities::EmailTaken)
        Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("ada@example.org")).should be_a(Punch::Auth::EmailIdentities::EmailTaken)
        Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("lovelace@example.org"), verified_at: Time.utc).as(Punch::Auth::EmailIdentity).verified?.should be_true
        Punch::Auth::EmailIdentities.list(db, 1).map(&.email.value).should eq(["ada@example.org", "lovelace@example.org"])
        Punch::Auth::EmailIdentities.find(db, PasswordsSpec.email("ADA@example.org")).try(&.user_id).should eq(1)
        Punch::Auth::EmailIdentities.verify(db, PasswordsSpec.email("ada@example.org")).should be_true
        Punch::Auth::EmailIdentities.find(db, PasswordsSpec.email("ada@example.org")).try(&.verified?).should be_true
        Punch::Auth::EmailIdentities.verify(db, PasswordsSpec.email("nobody@example.org")).should be_false
      end
    end
  end

  it "ends what came before an account's first verified address: other unverified addresses, sessions, tokens" do
    AuthSchema.with_spec_db do
      Punch::Spec.db.write do |db|
        claimed = Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("ada@example.org")).as(Punch::Auth::EmailIdentity)
        Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("mallory@example.net"))
        Punch::Auth::Sessions.create(db, 1, "password")
        Punch::Auth::APITokens.create(db, 1, "planted", Time.utc + 1.day)
        Punch::Auth::EmailIdentities.verified?(db, 1).should be_false

        Punch::Auth::EmailIdentities.verify(db, claimed.email).should be_true
        Punch::Auth::EmailIdentities.verified?(db, 1).should be_true
        Punch::Auth::EmailIdentities.list(db, 1).map(&.email.value).should eq(["ada@example.org"])
        Punch::Auth::Sessions.list(db, 1).should be_empty
        Punch::Auth::APITokens.list(db, 1).should be_empty

        # A later address is only verified.
        Punch::Auth::Sessions.create(db, 1, "password")
        later = Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("lovelace@example.org")).as(Punch::Auth::EmailIdentity)
        Punch::Auth::EmailIdentities.verify(db, later.email).should be_true
        Punch::Auth::Sessions.list(db, 1).size.should eq(1)
      end
    end
  end

  it "answers taken at the email field, like a unique violation" do
    taken = Punch::Auth::EmailIdentities::EmailTaken.new
    taken.rejection.errors.first.path.should eq(Punch::Rejection::Path{"email"})
    taken.rejection.errors.first.code.should eq("taken")
  end
end

describe "Punch::Auth::EmailIdentities.remove" do
  it "keeps a user's last way to sign in: one address, and once one is verified, one verified address" do
    AuthSchema.with_spec_db do
      Punch::Spec.db.write do |db|
        only = Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("ada@example.org")).as(Punch::Auth::EmailIdentity)
        Punch::Auth::EmailIdentities.remove(db, 1, only.id).should be_a(Punch::Auth::LastSignInMethod)
        Punch::Auth::EmailIdentities.remove(db, 2, only.id).should be_nil # not hers
        Punch::Auth::EmailIdentities.verify(db, only.email)
        typo = Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("ada@exmaple.org")).as(Punch::Auth::EmailIdentity)
        # The only verified address stays while the other is unverified.
        Punch::Auth::EmailIdentities.remove(db, 1, only.id).should be_a(Punch::Auth::LastSignInMethod)
        Punch::Auth::EmailIdentities.remove(db, 1, typo.id).as(Punch::Auth::EmailIdentity).email.value.should eq("ada@exmaple.org")
        second = Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("lovelace@example.org"), verified_at: Time.utc).as(Punch::Auth::EmailIdentity)
        Punch::Auth::EmailIdentities.remove(db, 1, only.id).should be_a(Punch::Auth::EmailIdentity)
        Punch::Auth::EmailIdentities.list(db, 1).map(&.id).should eq([second.id])
      end
    end
  end
end

describe "Passwords in endpoints" do
  it "publishes SignedIn, and SignInFailed after a refused sign-in although the Command rolled back" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      client = PasswordsSpec.client
      signed = Punch::Spec.published(Punch::Auth::SignInSucceeded) { client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "ada@example.org", password: PASSWORD}) }
      signed.map { |event| {event.user_id, event.method} }.should eq([{1_i64, "password"}])
      failed = Punch::Spec.published(Punch::Auth::SignInFailed) do
        client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "ada@example.org", password: "wrong password"}).status.code.should eq(422)
        client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "nobody@example.org", password: PASSWORD}).status.code.should eq(422)
      end
      failed.map { |event| {event.email.value, event.user_id} }.should eq([{"ada@example.org", 1_i64}, {"nobody@example.org", nil}])
    end
  end

  it "checks the signed-in user's own password before the transaction" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      client = PasswordsSpec.client.sign_in(1)
      wrong = client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: "wrong password", password: "a new password!"})
      wrong.json["code"].should eq("invalid_credentials")
      wrong.trace.root["punch.password"].should eq("invalid")
      changed = client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: PASSWORD, password: "a new password!"})
      changed.status.code.should eq(200)
      Punch::Auth::Passwords.verify_now("a new password!", PasswordsSpec.stored(1)).invalid?.should be_false
      # Without a password, nothing matches.
      Punch::Spec.db.write(&.exec("DELETE FROM punch_passwords"))
      client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: "", password: "a new password!"}).status.code.should eq(422)
      PasswordsSpec.client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: PASSWORD, password: "a new password!"}).status.code.should eq(401)
    end
  end

  it "limits own-password checks per user before hashing" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      client = PasswordsSpec.client.sign_in(1)
      3.times { client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: "guess", password: "a new password!"}) }
      limited = client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: PASSWORD, password: "a new password!"})
      limited.should be_rate_limited
      limited.trace.spans.none? { |span| span.name.in?("password.verify", "password.hash") }.should be_true
    end
  end

  it "hashes nothing for an own-password check without a working session or token" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      [HTTP::Headers{"Cookie" => "#{Punch::Auth::COOKIE}=made-up", "Sec-Fetch-Site" => "same-origin"}, Punch::Spec.bearer("made-up")].each do |headers|
        refused = PasswordsSpec.client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: "guess", password: "a new password!"}, headers: headers)
        refused.status.should eq(HTTP::Status::UNAUTHORIZED)
        refused.trace.spans.none? { |span| span.name.in?("password.verify", "password.hash") }.should be_true
      end
    end
  end

  it "signs up: hashes the new password before the transaction, stores it, and signs in" do
    AuthSchema.with_spec_db do
      PasswordsSpec.hashed_inside.clear
      client = PasswordsSpec.client
      response = client.post(PasswordsSpec::Accounts::SignUp.path, json: {name: "Hedy", email: "hedy@example.org", password: PASSWORD})
      response.status.should eq(HTTP::Status::OK)
      PasswordsSpec.hashed_inside.should eq([true])
      user_id = response.json["user_id"].as_i64
      Punch::Auth::Passwords.verify_now(PASSWORD, PasswordsSpec.stored(user_id)).valid?.should be_true
      response.headers["Set-Cookie"].should start_with("__Host-session=")
      response.trace.should have_span("password.hash")
      # The hash ran before the write transaction began.
      spans = response.trace.spans
      hashed = spans.find!(&.name.==("password.hash"))
      (hashed.started < spans.find!(&.name.ends_with?(" write")).started).should be_true

      again = client.post(PasswordsSpec::Accounts::SignUp.path, json: {name: "Hedy", email: "HEDY@example.org", password: PASSWORD})
      again.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      again.json["errors"].should eq(JSON.parse(%([{"path": ["email"], "code": "taken", "params": {}, "message": "Is already taken."}])))
      # The user row of the refused sign-up was rolled back.
      Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM users WHERE name = 'Hedy'", &.read(Int64))).should eq(1)

      short = client.post(PasswordsSpec::Accounts::SignUp.path, json: {name: "X", email: "x@example.org", password: "short"})
      short.json["errors"].should eq(JSON.parse(%([{"path": ["password"], "code": "too_short", "params": {"min": 12}, "message": "Must be at least 12 characters long."}])))
    end
  end

  it "signs in with the right password, and answers the same for a wrong one and an unknown address" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      Punch::Spec.db.write { |db| Punch::Auth::EmailIdentities.add(db, 2, PasswordsSpec.email("grace@example.org")) }
      client = PasswordsSpec.client
      signed_in = client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "Ada@example.org", password: PASSWORD})
      signed_in.json.should eq(JSON.parse(%({"user_id": 1})))
      signed_in.headers["Set-Cookie"].should start_with("__Host-session=")
      signed_in.trace.root["punch.password"].should eq("valid")
      signed_in.trace.should have_span("password.verify")

      answers = [
        {email: "ada@example.org", password: "wrong password"},
        {email: "nobody@example.org", password: PASSWORD},
        # Grace has an identity but no password.
        {email: "grace@example.org", password: PASSWORD},
      ].map do |attempt|
        response = PasswordsSpec.client.post(PasswordsSpec::Accounts::SignIn.path, json: attempt)
        response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
        response.headers["Set-Cookie"]?.should be_nil
        response.trace.root["punch.password"].should eq("invalid")
        response.trace.should have_span("password.verify")
        response.json.as_h.reject("request_id", "instance")
      end
      answers.uniq.size.should eq(1)
      answers.first["code"].should eq("invalid_credentials")
    end
  end

  it "replaces a hash with old parameters at sign-in" do
    AuthSchema.with_spec_db do
      Punch::Spec.db.write do |db|
        Punch::Auth::EmailIdentities.add(db, 1, PasswordsSpec.email("ada@example.org"))
        Punch::Auth::Passwords.set(db, 1, Punch::Auth::Passwords.hash_now(PASSWORD, 500))
      end
      response = PasswordsSpec.client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "ada@example.org", password: PASSWORD})
      response.status.should eq(HTTP::Status::OK)
      response.trace.root["punch.password"].should eq("rehashed")
      Punch::Auth::Passwords.parameters(PasswordsSpec.stored(1)).should eq("pbkdf2-sha256 i=1000")
    end
  end

  it "confirms nothing when the password changed between the check and the transaction" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      email = PasswordsSpec.email("ada@example.org")
      check = Punch::Auth::Passwords.check(Punch::Spec.db, email, PasswordsSpec.password(PASSWORD)).as(Punch::Auth::PasswordCheck)
      check.matched?.should be_true
      Punch::Spec.db.write { |db| Punch::Auth::Passwords.set(db, 1, Punch::Auth::Passwords.hash_now("another password!")) }
      Punch::Spec.db.write { |db| check.confirm(db) }.should be_nil

      check = Punch::Auth::Passwords.check(Punch::Spec.db, email, PasswordsSpec.password("another password!")).as(Punch::Auth::PasswordCheck)
      # The address moved to another user meanwhile.
      Punch::Spec.db.write(&.exec("UPDATE punch_email_identities SET user_id = 2"))
      Punch::Spec.db.write { |db| check.confirm(db) }.should be_nil
      Punch::Spec.db.write(&.exec("UPDATE punch_email_identities SET user_id = 1"))
      Punch::Spec.db.write { |db| check.confirm(db, PasswordsSpec::UserID) }.should eq(PasswordsSpec::UserID.parse(1))
    end
  end

  it "answers 503 with Retry-After before any transaction when the hasher is full" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      hasher = Punch::Auth::Passwords::Hasher.new(1, 1)
      gate = Channel(Nil).new
      results = Channel(Bool).new(8)
      PasswordsSpec.fill(hasher, gate, results)
      PasswordsSpec.with_hasher(hasher) do
        busy = PasswordsSpec.client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "ada@example.org", password: PASSWORD})
        busy.status.should eq(HTTP::Status::SERVICE_UNAVAILABLE)
        busy.json["code"].should eq("passwords_busy")
        busy.headers["Retry-After"].should eq("1")
        busy.trace.spans.none?(&.name.ends_with?(" write")).should be_true

        page = PasswordsSpec.client.submit(PasswordsSpec::Accounts::SignUp.action, form: {"name" => "Hedy", "email" => "hedy@example.org", "password" => PASSWORD})
        page.status.should eq(HTTP::Status::SERVICE_UNAVAILABLE)
        page.content_type.should eq("text/html")
        page.headers["Retry-After"].should eq("1")
      end
      (hasher.workers + 1).times { gate.send(nil) }
    end
  end

  it "writes password fields as password controls and never echoes them" do
    AuthSchema.with_spec_db do
      page = PasswordsSpec.client.visit(PasswordsSpec::Accounts::SignInPage.href)
      page.should have_element("input[name=password][type=password][autocomplete=current-password][required]")
      page.should have_element("input[name=email][inputmode=email][autocomplete=email]")
      signup = PasswordsSpec.client.visit(PasswordsSpec::Accounts::SignUpPage.href)
      signup.should have_element("input[name=password][type=password][autocomplete=new-password][minlength='12'][maxlength='256']")

      refused = PasswordsSpec.client.submit(PasswordsSpec::Accounts::SignIn.action, form: {"email" => "ada@example.org", "password" => "secret guess"})
      refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      refused.should have_element(".form-errors li[data-code=invalid_credentials]", text: /email address or password is wrong/)
      refused.should have_element("input[name=email][value='ada@example.org']")
      refused.body.should_not contain("secret guess")

      short = PasswordsSpec.client.submit(PasswordsSpec::Accounts::SignUp.action, form: {"name" => "X", "email" => "x@example.org", "password" => "tiny secret"})
      short.should have_field_error("password", "too_short")
      short.body.should_not contain("tiny secret")
    end
  end

  it "signs in through the form and redirects" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      client = PasswordsSpec.client
      client.submit(PasswordsSpec::Accounts::SignIn.action, form: {"email" => "ada@example.org", "password" => PASSWORD})
        .should redirect_to(PasswordsSpec::Accounts::SignInPage.href)
      client.cookies.has_key?(Punch::Auth::COOKIE).should be_true
    end
  end

  it "limits sign-in attempts per address" do
    AuthSchema.with_spec_db do
      client = PasswordsSpec.client
      5.times { client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "ada@example.org", password: "guess"}).status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY) }
      limited = client.post(PasswordsSpec::Accounts::SignIn.path, json: {email: "ADA@example.org", password: "guess"})
      limited.should be_rate_limited
      limited.trace.spans.none? { |span| span.name.in?("password.verify", "password.hash") }.should be_true
    end
  end

  it "hashes nothing for an own-password check without a working session or token" do
    AuthSchema.with_spec_db do
      Punch::Spec.password_account(1, "ada@example.org", PASSWORD)
      [HTTP::Headers{"Cookie" => "#{Punch::Auth::COOKIE}=made-up", "Sec-Fetch-Site" => "same-origin"}, Punch::Spec.bearer("made-up")].each do |headers|
        refused = PasswordsSpec.client.post(PasswordsSpec::Accounts::ChangePassword.path, json: {current_password: "guess", password: "a new password!"}, headers: headers)
        refused.status.should eq(HTTP::Status::UNAUTHORIZED)
        refused.trace.spans.none? { |span| span.name.in?("password.verify", "password.hash") }.should be_true
      end
    end
  end
end
