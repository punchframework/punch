require "../spec_helper"
require "../support/auth_schema"

private NOW = Time.utc(2026, 10, 13, 12, 0, 0)

# RFC 6238, appendix B: the SHA-1 secret and the last six digits of its
# eight-digit codes.
private RFC_SECRET  = "12345678901234567890".to_slice
private RFC_VECTORS = {
           59_i64 => "287082",
   1111111109_i64 => "081804",
   1111111111_i64 => "050471",
   1234567890_i64 => "005924",
   2000000000_i64 => "279037",
  20000000000_i64 => "353130",
}

private def code(text : String) : Punch::Auth::OneTimeCode
  Punch::Auth::OneTimeCode.parse(text).as(Punch::Auth::OneTimeCode)
end

private def with_ring(&) : Nil
  previous = Punch::KeyRing.current?
  Punch::KeyRing.current = Punch::KeyRing.new([Punch::KeyRing::Key.generate(1)])
  begin
    yield
  ensure
    previous.try { |ring| Punch::KeyRing.current = ring }
  end
end

module SecondFactorSpec
  struct UserID < Punch::TypedID
  end

  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  struct SignedIn
    include JSON::Serializable

    getter user_id : Int64
    getter method : String

    def initialize(@user_id, @method)
    end
  end

  # Stands in for the password step.
  @[Punch::Public]
  @[Punch::RateLimitExempt("spec")]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input

      getter user_id : UserID
    end

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : SignedIn | Punch::Auth::SecondFactorRequired
      case session = auth.sign_in(input.user_id, method: "password")
      in Punch::Auth::Session              then SignedIn.new(session.user_id, session.method)
      in Punch::Auth::SecondFactorRequired then session
      end
    end
  end

  @[Punch::Public]
  @[Punch::RateLimit(3, per: 15.minutes, by: :challenge)]
  struct Complete < Punch::Command
    struct Input
      include Punch::Input

      getter code : Punch::Auth::OneTimeCode
    end

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication,
             second_factor : Punch::Auth::SecondFactorCheck) : SignedIn | Punch::Auth::InvalidCode | Punch::Auth::SecondFactorExpired
      case session = second_factor.sign_in(db, auth)
      in Punch::Auth::Session                                       then SignedIn.new(session.user_id(UserID).value, session.method)
      in Punch::Auth::InvalidCode, Punch::Auth::SecondFactorExpired then session
      end
    end
  end

  struct Recent
    include Punch::Policy
    include Punch::Policy::RecentAuthentication

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, **params) : Punch::Policy::Decision
      recently_authenticated(db, actor.principal)
    end
  end

  # Something that needs a recent authentication.
  @[Punch::Authorize(Recent)]
  struct Sensitive < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Actor, _grant : Punch::Grant(Sensitive)) : Nil
    end
  end

  # Proving it again with the app's code.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimit(3, per: 15.minutes, by: :actor)]
  struct Reauthenticate < Punch::Command
    struct Input
      include Punch::Input

      getter code : Punch::Auth::OneTimeCode
    end

    def call(input : Input, db : Punch::Writer, actor : Actor, auth : Punch::Auth::Authentication, _grant : Punch::Grant(Reauthenticate),
             second_factor : Punch::Auth::OwnSecondFactorCheck) : Punch::Auth::InvalidCode?
      factor = second_factor.confirm(db) || return Punch::Auth::InvalidCode.new
      auth.renew(method: factor)
      nil
    end
  end

  @[Punch::Authorize(Punch::RecentlyAuthenticated)]
  struct ReadyMade < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Actor, _grant : Punch::Grant(ReadyMade)) : Nil
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end

  def self.user(id : Int64) : UserID
    UserID.parse(id).as(UserID)
  end

  def self.count(table : String) : Int64
    Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM #{table}", &.read(Int64))) || 0_i64
  end
end

describe Punch::Auth::TOTP do
  it "computes RFC 6238's codes" do
    RFC_VECTORS.each do |unix, expected|
      Punch::Auth::TOTP.code(RFC_SECRET, Time.unix(unix)).should eq(expected)
    end
  end

  it "accepts a code one step either side, once: never a step at or before the last used" do
    step = Punch::Auth::TOTP.step(NOW)
    {-1, 0, 1}.each do |offset|
      text = Punch::Auth::TOTP.code(RFC_SECRET, step + offset)
      Punch::Auth::TOTP.match(RFC_SECRET, text, NOW, 0_i64).should eq(step + offset)
      Punch::Auth::TOTP.match(RFC_SECRET, text, NOW, step + offset).should be_nil
    end
    Punch::Auth::TOTP.match(RFC_SECRET, Punch::Auth::TOTP.code(RFC_SECRET, step + 2), NOW, 0_i64).should be_nil
    Punch::Auth::TOTP.match(RFC_SECRET, Punch::Auth::TOTP.code(RFC_SECRET, step - 2), NOW, 0_i64).should be_nil
  end

  it "writes the otpauth URI that authenticator apps read" do
    Punch::Auth::TOTP.uri(RFC_SECRET, issuer: "Invoicing & Co", account: "ada@example.org").should eq(
      "otpauth://totp/Invoicing%20%26%20Co:ada%40example.org?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Invoicing+%26+Co&algorithm=SHA1&digits=6&period=30")
  end
end

describe Punch::Auth::TOTP::Base32 do
  it "encodes RFC 4648's examples without padding, and decodes either case" do
    {"" => "", "f" => "MY", "fo" => "MZXQ", "foo" => "MZXW6", "foob" => "MZXW6YQ", "fooba" => "MZXW6YTB", "foobar" => "MZXW6YTBOI"}.each do |plain, encoded|
      Punch::Auth::TOTP::Base32.encode(plain.to_slice).should eq(encoded)
      Punch::Auth::TOTP::Base32.decode(encoded.downcase).should eq(plain.to_slice)
    end
    Punch::Auth::TOTP::Base32.decode("MZ1").should be_nil
  end
end

describe Punch::Auth::OneTimeCode do
  it "takes six digits or a recovery code, as shown or typed, and never prints" do
    totp = code(" 123 456 ")
    totp.totp?.should be_true
    totp.unwrap.should eq("123456")
    recovery = code("ABCD-EFGH-IJKL-MNOP")
    recovery.recovery?.should be_true
    recovery.unwrap.should eq("abcdefghijklmnop")
    recovery.to_s.should eq("[REDACTED]")
    recovery.inspect.should_not contain("abcd")
    {"12345", "1234567", "abcd-efgh-ijkl-mno1", "abcdefghijklmnopq"}.each do |bad|
      Punch::Auth::OneTimeCode.parse(bad).should eq(Punch::Invalid.new("invalid_code"))
    end
    Punch::Auth::OneTimeCode.parse(" - ").should eq(Punch::Invalid.new("blank"))
  end
end

describe Punch::Auth::SecondFactors do
  it "forgets a setup that waited longer than an hour for its first code" do
    with_ring do
      AuthSchema.database do |database|
        setup = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.as(Punch::Auth::TOTPSetup)
        later = NOW + Punch::Auth::SecondFactors::SETUP_LIFETIME + 1.second
        database.read { |db| Punch::Auth::SecondFactors.setup(db, 1, now: later - 2.seconds) }.should_not be_nil
        database.read { |db| Punch::Auth::SecondFactors.setup(db, 1, now: later) }.should be_nil
        code = code(Punch::Auth::TOTP.code(setup.secret.unwrap, later))
        database.write { |db| Punch::Auth::SecondFactors.confirm(db, 1, code, now: later) }.should be_false
        database.read { |db| Punch::Auth::SecondFactors.enabled?(db, 1) }.should be_false
      end
    end
  end

  it "sets up an app: the secret is stored encrypted, and counts only once a code confirmed it" do
    with_ring do
      AuthSchema.database do |database|
        setup = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.as(Punch::Auth::TOTPSetup)
        secret = setup.secret.unwrap
        secret.size.should eq(20)
        setup.recovery_codes.unwrap.size.should eq(10)
        setup.secret_text.unwrap.should match(/\A([A-Z2-7]{4} ){7}[A-Z2-7]{4}\z/)
        stored = database.read(&.query_one?("SELECT secret FROM punch_totp_authenticators", &.read(Bytes)))
        stored.should_not eq(secret)
        stored.to_s.should_not contain(secret.to_s)
        database.read { |db| Punch::Auth::SecondFactors.setup(db, 1, now: NOW) }.try(&.secret.unwrap).should eq(secret)

        database.read { |db| Punch::Auth::SecondFactors.enabled?(db, 1) }.should be_false
        database.write { |db| Punch::Auth::SecondFactors.confirm(db, 1, code("000000"), now: NOW) }.should be_false
        database.write { |db| Punch::Auth::SecondFactors.confirm(db, 1, code(Punch::Auth::TOTP.code(secret, NOW)), now: NOW) }.should be_true
        database.read { |db| Punch::Auth::SecondFactors.enabled?(db, 1) }.should be_true
        database.read { |db| Punch::Auth::SecondFactors.setup(db, 1, now: NOW) }.should be_nil
        found = database.read { |db| Punch::Auth::SecondFactors.find(db, 1) }.should_not be_nil
        found.confirmed_at.should eq(NOW)
        found.recovery_codes.should eq(10)
        found.unseen_codes?.should be_false
        # Recovery codes are digests only.
        digests = database.read(&.query_all("SELECT code_hash FROM punch_recovery_codes ORDER BY code_hash", &.read(Bytes)))
        index = Punch::KeyRing.current.blind_index("punch.recovery_code")
        digests.should eq(setup.recovery_codes.unwrap.map { |text| index.digest(text.to_slice) }.sort_by!(&.hexstring))
        # Keyed: a copy of the table alone cannot test a guess.
        digests.should_not contain(Digest::SHA256.digest(setup.recovery_codes.unwrap.first))

        database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.should be_a(Punch::Auth::SecondFactorEnabled)
      end
    end
  end

  it "moves to the signing key with the re-encryption job, so the key that encrypted it can retire" do
    with_ring do
      AuthSchema.database do |database|
        setup = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.as(Punch::Auth::TOTPSetup)
        old = Punch::KeyRing.current.keys.first
        Punch::KeyRing.current = Punch::KeyRing.new([Punch::KeyRing::Key.generate(2), old])
        run = Punch::Database::Encryption.run(database)
        run.messages.should eq(["punch_totp_authenticators.secret: 1 encrypted again", "punch_totp_authenticators.unseen_codes: 1 encrypted again"])
        Punch::KeyRing.current = Punch::KeyRing.new([Punch::KeyRing.current.keys.first])
        database.read { |db| Punch::Auth::SecondFactors.setup(db, 1, now: NOW) }.try(&.secret.unwrap).should eq(setup.secret.unwrap)
        Punch::Database::Encryption.run(database).written.should be_empty
      end
    end
  end

  it "starts over when a setup was not confirmed" do
    with_ring do
      AuthSchema.database do |database|
        first = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.as(Punch::Auth::TOTPSetup)
        second = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW + 1.minute) }.as(Punch::Auth::TOTPSetup)
        second.secret.unwrap.should_not eq(first.secret.unwrap)
        database.read { |db| Punch::Auth::SecondFactors.setup(db, 1, now: NOW) }.try(&.secret.unwrap).should eq(second.secret.unwrap)
        old = code(Punch::Auth::TOTP.code(first.secret.unwrap, NOW + 1.minute))
        database.write { |db| Punch::Auth::SecondFactors.confirm(db, 1, old, now: NOW + 1.minute) }.should be_false
      end
    end
  end

  it "takes an app's code once, and each recovery code once" do
    with_ring do
      AuthSchema.database do |database|
        setup = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.as(Punch::Auth::TOTPSetup)
        secret = setup.secret.unwrap
        database.write { |db| Punch::Auth::SecondFactors.confirm(db, 1, code(Punch::Auth::TOTP.code(secret, NOW)), now: NOW) }
        later = NOW + 1.minute
        now_code = code(Punch::Auth::TOTP.code(secret, later))
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 1, now_code, later) }.should eq("totp")
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 1, now_code, later) }.should be_nil
        # The confirming code's step is used up too.
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 1, code(Punch::Auth::TOTP.code(secret, NOW)), NOW) }.should be_nil
        # Another user's authenticator is not this one's.
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 2, code(Punch::Auth::TOTP.code(secret, later + 30.seconds)), later + 30.seconds) }.should be_nil

        recovery = code(setup.recovery_codes.unwrap.first)
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 2, recovery, later) }.should be_nil
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 1, recovery, later) }.should eq("recovery_code")
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 1, recovery, later) }.should be_nil
        database.read { |db| Punch::Auth::SecondFactors.find(db, 1) }.try(&.recovery_codes).should eq(9)
      end
    end
  end

  it "replaces the recovery codes, shows the new ones until seen, and removes everything" do
    with_ring do
      AuthSchema.database do |database|
        setup = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.as(Punch::Auth::TOTPSetup)
        database.write { |db| Punch::Auth::SecondFactors.confirm(db, 1, code(Punch::Auth::TOTP.code(setup.secret.unwrap, NOW)), now: NOW) }
        database.read { |db| Punch::Auth::SecondFactors.new_recovery_codes(db, 1) }.should be_nil
        database.write { |db| Punch::Auth::SecondFactors.regenerate(db, 2, now: NOW) }.should be_false
        database.write { |db| Punch::Auth::SecondFactors.regenerate(db, 1, now: NOW) }.should be_true
        fresh = database.read { |db| Punch::Auth::SecondFactors.new_recovery_codes(db, 1) }.should_not be_nil
        fresh.unwrap.size.should eq(10)
        (fresh.unwrap & setup.recovery_codes.unwrap).should be_empty
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 1, code(setup.recovery_codes.unwrap.first), NOW) }.should be_nil
        database.write { |db| Punch::Auth::SecondFactors.verify(db, 1, code(fresh.unwrap.first), NOW) }.should eq("recovery_code")
        database.write { |db| Punch::Auth::SecondFactors.seen(db, 1) }
        database.read { |db| Punch::Auth::SecondFactors.new_recovery_codes(db, 1) }.should be_nil

        database.write { |db| Punch::Auth::SecondFactors.remove(db, 1) }.should be_true
        database.read { |db| Punch::Auth::SecondFactors.enabled?(db, 1) }.should be_false
        database.read(&.query_one?("SELECT count(*) FROM punch_recovery_codes", &.read(Int64))).should eq(0)
        database.write { |db| Punch::Auth::SecondFactors.remove(db, 1) }.should be_false
      end
    end
  end

  it "raises rather than refuse quietly when the secret does not decrypt" do
    AuthSchema.database do |database|
      setup = nil
      with_ring { setup = database.write { |db| Punch::Auth::SecondFactors.start(db, 1, now: NOW) }.as(Punch::Auth::TOTPSetup) }
      with_ring do
        expect_raises(Punch::Auth::SecondFactors::Undecryptable) { database.read { |db| Punch::Auth::SecondFactors.setup(db, 1, now: NOW) } }
      end
    end
  end
end

describe "Signing in with a second factor" do
  it "signs in at once without one" do
    AuthSchema.with_spec_db do
      response = SecondFactorSpec.client.post(SecondFactorSpec::SignIn.path, json: {user_id: 1})
      response.json.should eq(JSON.parse(%({"user_id": 1, "method": "password"})))
    end
  end

  it "asks for the code after the password: no session yet, a challenge in its own cookie" do
    with_ring do
      AuthSchema.with_spec_db do
        Punch::Spec.second_factor(1)
        client = SecondFactorSpec.client.sign_in(SecondFactorSpec.user(2))
        response = client.post(SecondFactorSpec::SignIn.path, json: {user_id: 1})
        response.status.should eq(HTTP::Status::OK)
        response.json.should eq(JSON.parse(%({"second_factor": "totp"})))
        cookies = response.headers.get("Set-Cookie")
        cookies.should contain("__Host-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax")
        challenge = cookies.find!(&.starts_with?("__Host-second-factor="))
        challenge.should contain("Max-Age=600; Secure; HttpOnly; SameSite=Lax")
        # The session the request came with ended; none began.
        SecondFactorSpec.count("punch_sessions").should eq(0)
        Punch::Spec.db.read(&.query_one?("SELECT subject FROM punch_one_time_tokens WHERE purpose = 'second_factor'", &.read(String))).should eq("password")
      end
    end
  end

  it "completes with the app's code, once, as password+totp; a wrong code leaves the challenge for another try" do
    with_ring do
      AuthSchema.with_spec_db do
        secret = Punch::Spec.second_factor(1)
        client = SecondFactorSpec.client
        client.post(SecondFactorSpec::SignIn.path, json: {user_id: 1})

        wrong = client.post(SecondFactorSpec::Complete.path, json: {code: "000000"})
        wrong.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
        wrong.json["code"].should eq("invalid_code")
        SecondFactorSpec.count("punch_sessions").should eq(0)

        response = client.post(SecondFactorSpec::Complete.path, json: {code: Punch::Spec.totp_code(secret)})
        response.json.should eq(JSON.parse(%({"user_id": 1, "method": "password+totp"})))
        response.headers.get("Set-Cookie").should contain("__Host-second-factor=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax")
        SecondFactorSpec.count("punch_sessions").should eq(1)
        SecondFactorSpec.count("punch_one_time_tokens").should eq(0)

        # The challenge is gone, and so is the code.
        again = client.post(SecondFactorSpec::Complete.path, json: {code: Punch::Spec.totp_code(secret)})
        again.json["code"].should eq("second_factor_expired")
      end
    end
  end

  it "completes with a recovery code, which then is used up" do
    with_ring do
      AuthSchema.with_spec_db do
        recovery = Punch::Spec.db.write do |db|
          setup = Punch::Auth::SecondFactors.start(db, 1).as(Punch::Auth::TOTPSetup)
          Punch::Auth::SecondFactors.confirm(db, 1, code(Punch::Auth::TOTP.code(setup.secret.unwrap, Time.utc)))
          setup.recovery_codes.unwrap.first
        end
        client = SecondFactorSpec.client
        client.post(SecondFactorSpec::SignIn.path, json: {user_id: 1})
        response = client.post(SecondFactorSpec::Complete.path, json: {code: Punch::Auth::SecondFactors.format(recovery)})
        response.json["method"].should eq("password+recovery_code")
        Punch::Spec.db.read { |db| Punch::Auth::SecondFactors.find(db, 1) }.try(&.recovery_codes).should eq(9)
      end
    end
  end

  it "refuses without a challenge, and caps the tries per user" do
    with_ring do
      AuthSchema.with_spec_db do
        Punch::RateLimits.reset
        Punch::Spec.second_factor(1)
        SecondFactorSpec.client.post(SecondFactorSpec::Complete.path, json: {code: "123456"}).json["code"].should eq("second_factor_expired")

        # A new challenge for the same user does not reset the count.
        3.times do
          client = SecondFactorSpec.client
          client.post(SecondFactorSpec::SignIn.path, json: {user_id: 1})
          client.post(SecondFactorSpec::Complete.path, json: {code: "000000"}).json["code"].should eq("invalid_code")
        end
        client = SecondFactorSpec.client
        client.post(SecondFactorSpec::SignIn.path, json: {user_id: 1})
        limited = client.post(SecondFactorSpec::Complete.path, json: {code: "000000"})
        limited.status.should eq(HTTP::Status::TOO_MANY_REQUESTS)
        limited.headers["RateLimit-Policy"].should contain("second_factor_spec.complete.challenge")
        Punch::RateLimits.reset
      end
    end
  end

  it "does not let a challenge from one browser finish in another" do
    with_ring do
      AuthSchema.with_spec_db do
        secret = Punch::Spec.second_factor(1)
        SecondFactorSpec.client.post(SecondFactorSpec::SignIn.path, json: {user_id: 1})
        other = SecondFactorSpec.client.post(SecondFactorSpec::Complete.path, json: {code: Punch::Spec.totp_code(secret)})
        other.json["code"].should eq("second_factor_expired")
      end
    end
  end
end

describe Punch::Policy::RecentAuthentication do
  it "allows a fresh session, asks a stale one to prove it again, and forbids an API token" do
    AuthSchema.with_spec_db do
      SecondFactorSpec.client.sign_in(SecondFactorSpec.user(1)).post(SecondFactorSpec::Sensitive.path).status.should eq(HTTP::Status::NO_CONTENT)
      stale = SecondFactorSpec.client.sign_in(SecondFactorSpec.user(1), now: Time.utc - 16.minutes).post(SecondFactorSpec::Sensitive.path)
      stale.status.should eq(HTTP::Status::FORBIDDEN)
      stale.json["code"].should eq("reauthentication_required")
      token = Punch::Spec.api_token(1)
      SecondFactorSpec.client.post(SecondFactorSpec::Sensitive.path, headers: Punch::Spec.bearer(token)).json["code"].should eq("forbidden")
      SecondFactorSpec.client.sign_in(SecondFactorSpec.user(1)).post(SecondFactorSpec::ReadyMade.path).status.should eq(HTTP::Status::NO_CONTENT)
    end
  end

  it "counts only a proof with the second factor for a user who has one" do
    with_ring do
      AuthSchema.with_spec_db do
        secret = Punch::Spec.second_factor(1)
        client = SecondFactorSpec.client.sign_in(SecondFactorSpec.user(1)) # method: password
        client.post(SecondFactorSpec::Sensitive.path).json["code"].should eq("reauthentication_required")

        client.post(SecondFactorSpec::Reauthenticate.path, json: {code: "000000"}).json["code"].should eq("invalid_code")
        client.post(SecondFactorSpec::Reauthenticate.path, json: {code: Punch::Spec.totp_code(secret)}).status.should eq(HTTP::Status::NO_CONTENT)
        client.post(SecondFactorSpec::Sensitive.path).status.should eq(HTTP::Status::NO_CONTENT)
        Punch::Spec.db.read(&.query_one?("SELECT method FROM punch_sessions", &.read(String))).should eq("totp")
      end
    end
  end

  it "documents 403 reauthentication_required only where the policy asks for it" do
    registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
    entry = ->(operation : String) { Punch::Routing.routes.find!(&.operation.== operation) }
    sensitive = Punch::OpenAPI.operation(SecondFactorSpec::Sensitive, entry.call("SecondFactorSpec::Sensitive"), registry)
    sensitive["responses"]["403"].to_json.should contain("reauthentication_required")
    ready = Punch::OpenAPI.operation(SecondFactorSpec::ReadyMade, entry.call("SecondFactorSpec::ReadyMade"), registry)
    ready["responses"]["403"].to_json.should contain("reauthentication_required")
    other = Punch::OpenAPI.operation(SecondFactorSpec::Reauthenticate, entry.call("SecondFactorSpec::Reauthenticate"), registry)
    other["responses"]["403"].to_json.should_not contain("reauthentication_required")
    complete = Punch::OpenAPI.operation(SecondFactorSpec::Complete, entry.call("SecondFactorSpec::Complete"), registry)
    complete["security"]?.should be_nil
  end
end
