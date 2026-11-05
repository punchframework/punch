require "../spec_helper"
require "file_utils"
require "../../src/punch/cli"

private def creds(*args : String, input : String? = nil) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = if input
           command = Punch::CLI::Commands::CredsSet.new(Punch::CLI::COMMANDS)
           command.input = IO::Memory.new(input)
           argv = args.to_a[1..]
           json = argv.delete("--json")
           command.json_output = !json.nil?
           outcome = command.run(argv)

           case outcome
           in Punch::CLI::Report  then json ? outcome.to_json(stdout) : outcome.to_text(stdout); 0
           in Punch::CLI::Failure then stderr.puts(outcome.message); outcome.exit_code
           end
         else
           Punch::CLI.run(args.to_a, stdout, stderr)
         end
  {code, stdout.to_s, stderr.to_s}
end

# Runs the block in a fresh directory; the examples here change the working
# directory and the environment, so they run one at a time.
private def in_app(& : -> Nil) : Nil
  directory = File.tempname("punch-creds-app")
  Dir.mkdir(directory)
  begin
    Dir.cd(directory) { yield }
  ensure
    FileUtils.rm_rf(directory)
    %w[PUNCH_ENV PUNCH_MASTER_KEY EDITOR VISUAL].each { |name| ENV.delete(name) }
  end
end

describe "punch creds" do
  it "initializes an environment: a private key file, an encrypted file, and a .gitignore rule" do
    in_app do
      File.write(".gitignore", "/lib/")
      code, stdout, _ = creds("creds:init", "--env", "staging")
      code.should eq(0)
      stdout.should contain("written   config/credentials/staging.key")
      File.info("config/credentials/staging.key").permissions.value.should eq(0o600)
      File.read(".gitignore").should eq("/lib/\n/config/credentials/*.key\n")
      File.read("config/credentials/staging.yml.enc").should_not contain("Credentials")
      creds("creds:init", "--env", "staging")[2].should contain("config/credentials/staging.yml.enc exists already")
      creds("creds:init", "--env", "Staging")[0].should eq(2)
      creds("creds:init", "--env", "test")
      File.read(".gitignore").should eq("/lib/\n/config/credentials/*.key\n")
    end
  end

  it "sets values from stdin and shows them redacted unless revealed" do
    in_app do
      creds("creds:init")
      creds("creds:set", "stripe.secret_key", input: "sk_live_1\n")[0].should eq(0)
      creds("creds:set", "smtp.port", input: "587")[0].should eq(0)
      code, stdout, _ = creds("creds:show")
      code.should eq(0)
      stdout.should eq(<<-YAML)
        # config/credentials/development.yml.enc, opened with config/credentials/development.key
        stripe:
          secret_key: '[REDACTED]'
        smtp:
          port: '[REDACTED]'

        YAML
      JSON.parse(creds("creds:show", "--reveal", "--json")[1])["credentials"].should eq(
        JSON.parse(%({"stripe": {"secret_key": "sk_live_1"}, "smtp": {"port": "587"}})))
      creds("creds:set", "stripe", input: "x")[2].should contain("stripe is a group")
      creds("creds:set", "stripe.secret_key.part", input: "x")[2].should contain("stripe.secret_key holds a value")
      creds("creds:set", "stripe.secret_key", input: "")[2].should contain("No value on stdin")
      creds("creds:set", "Stripe.key", input: "x")[0].should eq(2)
      creds("creds:unset", "smtp")[0].should eq(0)
      creds("creds:unset", "smtp")[2].should contain("smtp is not in config/credentials/development.yml.enc")
      JSON.parse(creds("creds:show", "--reveal", "--json")[1])["credentials"].should eq(JSON.parse(%({"stripe": {"secret_key": "sk_live_1"}})))
    end
  end

  it "edits in $EDITOR and refuses to write invalid YAML" do
    in_app do
      creds("creds:init", "--env", "test")
      File.write("editor.sh", "#!/bin/sh\nprintf 'api:\\n  key: k1\\n' > \"$1\"\n")
      File.chmod("editor.sh", 0o755)
      ENV["EDITOR"] = File.expand_path("editor.sh")
      creds("creds:edit", "--env", "test")[0].should eq(0)
      JSON.parse(creds("creds:show", "--env", "test", "--reveal", "--json")[1])["credentials"].should eq(JSON.parse(%({"api": {"key": "k1"}})))
      creds("creds:edit", "--env", "test")[1].should contain("unchanged")

      File.write("editor.sh", "#!/bin/sh\nprintf 'api: [broken\\n' > \"$1\"\n")
      code, _, stderr = creds("creds:edit", "--env", "test")
      code.should eq(1)
      stderr.should contain("config/credentials/test.yml.enc is not valid YAML")
      stderr.should contain("nothing was written")
      JSON.parse(creds("creds:show", "--env", "test", "--reveal", "--json")[1])["credentials"]["api"]["key"].should eq("k1")

      File.write("editor.sh", "#!/bin/sh\nexit 3\n")
      creds("creds:edit", "--env", "test")[2].should contain("The editor exited with 3; nothing was written.")
      Dir.glob(File.join(Dir.tempdir, "*punch-creds")).should be_empty
    end
  end

  it "rekeys: the new key opens the same content and the old one no longer does" do
    in_app do
      creds("creds:init")
      creds("creds:set", "api.key", input: "k1")
      old = File.read("config/credentials/development.key")
      creds("creds:rekey")[0].should eq(0)
      File.read("config/credentials/development.key").should_not eq(old)
      File.exists?("config/credentials/development.key.new").should be_false
      JSON.parse(creds("creds:show", "--reveal", "--json")[1])["credentials"].should eq(JSON.parse(%({"api": {"key": "k1"}})))
      ENV["PUNCH_MASTER_KEY"] = old
      creds("creds:show")[2].should contain("config/credentials/development.yml.enc was encrypted with another key than PUNCH_MASTER_KEY")
    end
  end

  it "explains a missing key or file and a malformed key" do
    in_app do
      creds("creds:show", "--env", "production")[2].should contain("config/credentials/production.yml.enc does not exist. Run 'punch creds:init --env production'.")
      creds("creds:init", "--env", "production")
      File.delete("config/credentials/production.key")
      creds("creds:show", "--env", "production")[2].should contain("No key for production: set PUNCH_MASTER_KEY or add config/credentials/production.key.")
      ENV["PUNCH_MASTER_KEY"] = "not-a-key"
      creds("creds:show", "--env", "production")[2].should contain("PUNCH_MASTER_KEY must hold 64 hexadecimal characters")
    end
  end
end

private def ring_ids(environment = "development") : Array({Int64, String})
  JSON.parse(creds("keys", "--env", environment, "--json")[1])["keys"].as_a.map { |key| {key["id"].as_i64, key["state"].as_s} }
end

describe "punch keys" do
  it "rotates from rotate to retire, keeping what the old key signed readable until retired" do
    in_app do
      creds("creds:init")
      creds("keys")[1].should contain("No key ring")
      creds("keys:rotate")[1].should contain("Created key 1")
      ring_ids.should eq([{1, "signing"}])
      first = Punch::KeyRing.parse(Punch::CLI::Commands::Creds.read_tree("development").as(Tuple)[0]["secret_key_base"].as(String)).as(Punch::KeyRing)
      link = first.signer("invoice_link").sign_text("42")

      creds("keys:rotate")[0].should eq(0)
      ring_ids.should eq([{2, "pending"}, {1, "signing"}])
      creds("keys:rotate")[2].should contain("Key 2 is pending already")
      creds("keys:promote")[1].should contain("Key 2 signs now; key 1 is still accepted")
      ring_ids.should eq([{2, "signing"}, {1, "accepted"}])
      ring = Punch::KeyRing.parse(Punch::CLI::Commands::Creds.read_tree("development").as(Tuple)[0]["secret_key_base"].as(String)).as(Punch::KeyRing)
      ring.signer("invoice_link").verify_text(link).should eq("42")

      creds("keys:retire", "2")[2].should contain("Key 2 signs")
      creds("keys:retire", "7")[2].should contain("There is no key 7")
      creds("keys:retire")[0].should eq(2)
      creds("keys:retire", "1")[1].should contain("Retired key 1")
      ring = Punch::KeyRing.parse(Punch::CLI::Commands::Creds.read_tree("development").as(Tuple)[0]["secret_key_base"].as(String)).as(Punch::KeyRing)
      ring.signer("invoice_link").verify_text(link).should be_nil
      creds("keys:promote")[2].should contain("No key is pending")
    end
  end

  it "revokes every key at once" do
    in_app do
      creds("creds:init", "--env", "production")
      creds("keys:rotate", "--env", "production")
      creds("keys:rotate", "--env", "production")
      creds("keys:rotate", "--revoke", "--env", "production")[1].should contain("Revoked keys 2, 1")
      ring_ids("production").should eq([{3, "signing"}])
    end
  end

  it "never shows key material" do
    in_app do
      creds("creds:init")
      creds("keys:rotate")
      secret = Punch::CLI::Commands::Creds.read_tree("development").as(Tuple)[0]["secret_key_base"].as(String).split(':')[2].strip
      {creds("keys"), creds("keys", "--json"), creds("keys:rotate"), creds("creds:show")}.each do |run|
        (run[1] + run[2]).should_not contain(secret)
      end
    end
  end
end

describe "punch keys:public-id" do
  it "creates the key of public IDs once, and replaces it only when asked" do
    in_app do
      creds("creds:init")
      creds("keys:public-id")[1].should contain("Created public_id_key")
      key = Punch::CLI::Commands::Creds.read_tree("development").as(Tuple)[0]["public_id_key"].as(String)
      Punch::PublicIDKey.parse(key).should be_a(Punch::PublicIDKey)

      code, _, stderr = creds("keys:public-id")
      {code, stderr.includes?("changes every public ID")}.should eq({1, true})
      Punch::CLI::Commands::Creds.read_tree("development").as(Tuple)[0]["public_id_key"].should eq(key)

      creds("keys:public-id", "--replace")[1].should contain("Replaced public_id_key")
      replaced = Punch::CLI::Commands::Creds.read_tree("development").as(Tuple)[0]["public_id_key"].as(String)
      replaced.should_not eq(key)
      {creds("keys:public-id", "--replace"), creds("creds:show")}.each do |run|
        (run[1] + run[2]).should_not contain(replaced)
      end
    end
  end
end
