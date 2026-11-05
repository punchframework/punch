require "../spec_helper"

module CredentialsSpec
  enum Mode
    Sandbox
    Live
  end

  struct Stripe
    include Punch::Credentials

    getter secret_key : Punch::Secret(String)
    getter timeout : Int32 = 10
    getter mode : Mode = Mode::Sandbox
  end

  struct Smtp
    include Punch::Credentials

    getter host : String
    getter port : Int32 = 587
    getter password : Punch::Secret(String)?
    getter? starttls : Bool = true
  end

  struct App
    include Punch::Credentials

    getter stripe : Stripe
    getter smtp : Smtp
    getter support_email : Punch::Email
  end

  struct Flat
    include Punch::Credentials

    getter path : String?
  end

  struct Single
    include Punch::Credentials

    getter region : String?
  end

  struct DocumentID < Punch::TypedID
    public_id "crdoc"
  end

  struct WithPublicIDs
    include Punch::Credentials

    getter public_id_key : Punch::PublicIDKey
  end

  KEY = Punch::Credentials::MasterKey.new(Bytes.new(32, 3_u8), "spec")

  def self.source(yaml : String?, env = {} of String => String) : Punch::Credentials::Source
    embedded = yaml.try { |text| Punch::Credentials::EncryptedFile.encrypt(text, KEY) }
    Punch::Credentials::Source.open("test", embedded, env.merge({"PUNCH_MASTER_KEY" => KEY.to_text}))
  end

  FILE = <<-YAML
    stripe:
      secret_key: sk_file
      timeout: 30
    smtp:
      host: smtp.example.com
    support_email: help@example.com
    YAML
end

describe Punch::Credentials do
  it "loads typed values from the file, with defaults and nilable fields" do
    app = CredentialsSpec::App.load(CredentialsSpec.source(CredentialsSpec::FILE)).as(CredentialsSpec::App)
    app.stripe.secret_key.unwrap.should eq("sk_file")
    app.stripe.timeout.should eq(30)
    app.stripe.mode.should eq(CredentialsSpec::Mode::Sandbox)
    app.smtp.host.should eq("smtp.example.com")
    app.smtp.port.should eq(587)
    app.smtp.password.should be_nil
    app.smtp.starttls?.should be_true
    app.support_email.should eq(Punch::Email.parse("help@example.com"))
  end

  it "prefers the environment, named by the path in capitals joined by __" do
    env = {"STRIPE__SECRET_KEY" => "sk_env", "SMTP__PORT" => "2525", "STRIPE__MODE" => "live", "SMTP__STARTTLS" => "false"}
    app = CredentialsSpec::App.load(CredentialsSpec.source(CredentialsSpec::FILE, env)).as(CredentialsSpec::App)
    app.stripe.secret_key.unwrap.should eq("sk_env")
    app.smtp.port.should eq(2525)
    app.stripe.mode.should eq(CredentialsSpec::Mode::Live)
    app.smtp.starttls?.should be_false
  end

  it "loads from the environment alone when there is no file" do
    env = {"STRIPE__SECRET_KEY" => "sk", "SMTP__HOST" => "mail", "SUPPORT_EMAIL" => "a@example.com"}
    CredentialsSpec::App.load(CredentialsSpec.source(nil, env)).should be_a(CredentialsSpec::App)
  end

  it "reports every problem at once, naming the variable and the file but never a value" do
    yaml = <<-YAML
      stripe:
        timeout: soon
        secret_kee: sk_typo
      smtp: {}
      support_email: not-an-email-sk_secret
      extra: 1
      YAML
    problems = CredentialsSpec::App.load(CredentialsSpec.source(yaml)).as(Array(String))
    problems.should eq([
      "extra in config/credentials/test.yml.enc is not a declared credential",
      "stripe.secret_kee in config/credentials/test.yml.enc is not a declared credential",
      "stripe.secret_key is missing: set STRIPE__SECRET_KEY or add it to config/credentials/test.yml.enc",
      "stripe.timeout from stripe.timeout in config/credentials/test.yml.enc is not valid: expected_integer",
      "smtp.host is missing: set SMTP__HOST or add it to config/credentials/test.yml.enc",
      "support_email from support_email in config/credentials/test.yml.enc is not valid: invalid_email",
    ])
    problems.join.should_not contain("sk_")
    problems.join.should_not contain("soon")
  end

  it "keeps scalars as written: no YAML booleans, numbers, or dates by accident" do
    yaml = "stripe:\n  secret_key: no\nsmtp:\n  host: 2026-10-09\nsupport_email: a@example.com\n"
    app = CredentialsSpec::App.load(CredentialsSpec.source(yaml)).as(CredentialsSpec::App)
    app.stripe.secret_key.unwrap.should eq("no")
    app.smtp.host.should eq("2026-10-09")
  end

  it "treats null as absent and rejects groups given as values" do
    yaml = "stripe: sk\nsmtp:\n  host: ~\nsupport_email: a@example.com\n"
    problems = CredentialsSpec::App.load(CredentialsSpec.source(yaml)).as(Array(String))
    problems.should contain("stripe in config/credentials/test.yml.enc must be a mapping of secret_key, timeout, mode")
    problems.should contain("smtp.host is missing: set SMTP__HOST or add it to config/credentials/test.yml.enc")
  end

  it "records where each value came from, without the values of secrets" do
    source = CredentialsSpec.source(CredentialsSpec::FILE, {"SMTP__PORT" => "25"})
    CredentialsSpec::App.load(source)
    entries = source.entries.to_h { |entry| {entry.path, entry} }
    entries["stripe.secret_key"].should eq(Punch::Credentials::Source::Entry.new(
      "stripe.secret_key", :file, "stripe.secret_key in config/credentials/test.yml.enc", true, nil))
    entries["smtp.port"].should eq(Punch::Credentials::Source::Entry.new("smtp.port", :environment, "SMTP__PORT", false, "25"))
    entries["stripe.mode"].should eq(Punch::Credentials::Source::Entry.new("stripe.mode", :default, nil, false, "Sandbox"))
    entries["smtp.password"].origin.should eq(Punch::Credentials::Source::Origin::Absent)
  end

  it "does not read standard variables such as PATH for a top-level credential" do
    source = Punch::Credentials::Source.open("test", nil, {"PATH" => "/usr/bin"})
    problems = CredentialsSpec::Flat.load(source).as(Array(String))
    problems.should eq(["path would read the environment variable PATH; rename it or move it into a group"])
  end

  it "explains a missing value when the file is compiled in but has no key" do
    embedded = Punch::Credentials::EncryptedFile.encrypt(CredentialsSpec::FILE, CredentialsSpec::KEY)
    directory = File.tempname("punch-no-key")
    source = Punch::Credentials::Source.open("test", embedded, {} of String => String, directory: directory)
    problems = CredentialsSpec::App.load(source).as(Array(String))
    problems.first.should eq("stripe.secret_key is missing: set STRIPE__SECRET_KEY or add it to #{directory}/test.yml.enc " \
                             "(#{directory}/test.yml.enc is compiled in, but there is no key: set PUNCH_MASTER_KEY or add #{directory}/test.key)")
  end

  it "stops at a wrong key or a damaged file" do
    embedded = Punch::Credentials::EncryptedFile.encrypt(CredentialsSpec::FILE, Punch::Credentials::MasterKey.generate("other"))
    source = Punch::Credentials::Source.open("test", embedded, {"PUNCH_MASTER_KEY" => CredentialsSpec::KEY.to_text})
    CredentialsSpec::App.load(source).as(Array(String)).first.should eq(
      "config/credentials/test.yml.enc was encrypted with another key than PUNCH_MASTER_KEY")
  end

  it "rejects YAML it cannot map: duplicate keys, aliases, a list at the top" do
    {
      "a: 1\na: 2\n"     => "'a' appears twice",
      "a: &x 1\nb: *x\n" => "anchors and aliases are not supported",
      "- 1\n"            => "must hold a YAML mapping at the top",
      "a: [unclosed\n"   => "is not valid YAML",
    }.each do |yaml, message|
      outcome = Punch::Credentials::YAMLTree.parse(yaml, "f.yml.enc")
      outcome.as(String).should contain(message)
    end
    Punch::Credentials::YAMLTree.parse("# only a comment\n", "f").should eq({} of String => Punch::Credentials::Tree)
  end

  it "dumps a tree that reads back the same, quoting strings that look like null" do
    tree = {"a" => "null", "b" => {"c" => "x: y", "d" => ""} of String => Punch::Credentials::Tree, "e" => "line\nbreak"} of String => Punch::Credentials::Tree
    Punch::Credentials::YAMLTree.parse(Punch::Credentials::YAMLTree.dump(tree), "f").should eq(tree)
  end

  it "raises a bug when current is read before loading" do
    expect_raises(Punch::Credentials::NotLoaded, /CredentialsSpec::Flat has not been loaded/) { CredentialsSpec::Flat.current }
  end
end

describe Punch::PublicIDKey do
  it "loads as a secret, installs as the key of public IDs, and never prints" do
    previous = Punch::Crypto::PublicIDs.root?
    text = "7c" * 32
    source = CredentialsSpec.source("public_id_key: #{text}")
    value = CredentialsSpec::WithPublicIDs.load(source).as(CredentialsSpec::WithPublicIDs)
    source.entries.first.should eq(Punch::Credentials::Source::Entry.new(
      "public_id_key", :file, "public_id_key in config/credentials/test.yml.enc", true, nil))
    {value.public_id_key.to_s, value.public_id_key.inspect}.should eq({"Punch::PublicIDKey", "Punch::PublicIDKey"})
    Punch::Credentials.install(value)
    Punch::Crypto::PublicIDs.root?.should eq(text.hexbytes)
  ensure
    previous.try { |root| Punch::Crypto::PublicIDs.root = root }
  end

  it "rejects a key of the wrong form" do
    problems = CredentialsSpec::WithPublicIDs.load(CredentialsSpec.source("public_id_key: abc")).as(Array(String))
    problems.first.should contain("public_id_key")
  end

  it "stops the boot of an app with public IDs but no key" do
    single = CredentialsSpec::Single.load(CredentialsSpec.source("region: eu-1")).as(CredentialsSpec::Single)
    Punch::TypedID.public_prefixes.should contain("crdoc")
    Punch::Credentials.public_id_problems(single).first.should start_with("public_id_key: missing; the app has public IDs (")
    with_key = CredentialsSpec::WithPublicIDs.load(CredentialsSpec.source("public_id_key: #{"7c" * 32}")).as(CredentialsSpec::WithPublicIDs)
    Punch::Credentials.public_id_problems(with_key).should be_empty
  end
end

describe "Punch::Spec.credentials" do
  it "loads a credentials type from YAML and makes it current" do
    single = Punch::Spec.credentials(CredentialsSpec::Single, "region: eu-1")
    single.region.should eq("eu-1")
    CredentialsSpec::Single.current.region.should eq("eu-1")
    app = Punch::Spec.credentials(CredentialsSpec::App, CredentialsSpec::FILE, env: {"SMTP__PORT" => "25"})
    app.smtp.port.should eq(25)
  end

  it "fails the example with every problem" do
    expect_raises(Spec::AssertionFailed, /CredentialsSpec::App does not load:\n  stripe.secret_key is missing/) do
      Punch::Spec.credentials(CredentialsSpec::App, "smtp:\n  host: h\nsupport_email: a@example.com\n")
    end
  end
end
