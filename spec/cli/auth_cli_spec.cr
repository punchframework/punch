require "../spec_helper"
require "../support/auth_schema"
require "../../src/punch/cli"

private def run(*args : String) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::APP_COMMANDS)
  {code, stdout.to_s, stderr.to_s}
end

private def json(*args : String) : JSON::Any
  JSON.parse(run(*args, "--json")[1])
end

# A storage directory whose primary.db has users 1 and 2 and Punch's auth
# tables, as PUNCH_STORAGE for the block.
private def with_storage(&)
  storage = File.tempname("punch-auth-cli")
  Dir.mkdir(storage)
  database = Punch::Database.open(File.join(storage, "primary.db"))
  Punch::Migrations::Schema.load(database, AuthSchema::SQL, "auth")
  database.write(&.exec("INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace')"))
  database.close
  ENV["PUNCH_STORAGE"] = storage
  yield storage
ensure
  ENV.delete("PUNCH_STORAGE")
  FileUtils.rm_rf(storage) if storage
end

describe "punch tokens" do
  it "creates a token, shows it once, lists and revokes it" do
    with_storage do
      code, stdout, stderr = run("tokens:create", "--user", "1", "--name", "CI deploy", "--days", "7")
      {code, stderr}.should eq({0, ""})
      token = stdout.lines.first
      token.should match(/\Apunch_[0-9A-Za-z]{49}\z/)
      stdout.lines[1].should start_with("Token 1 for user 1, expires ")

      listed = json("tokens", "--user", "1")["tokens"].as_a
      listed.map(&.["name"]).should eq(["CI deploy"])
      run("tokens").to_s.should_not contain(token)
      json("tokens", "--user", "2")["tokens"].as_a.should be_empty

      json("tokens:revoke", "1").should eq(JSON.parse(%({"revoked": 1})))
      json("tokens:revoke", "1")["error"]["code"].should eq("not_found")
      json("tokens")["tokens"].as_a.should be_empty
    end
  end

  it "refuses what cannot be a token" do
    with_storage do
      json("tokens:create", "--user", "1", "--name", "x", "--days", "400")["error"]["code"].should eq("invalid_out_of_range")
      json("tokens:create", "--user", "9", "--name", "x")["error"]["code"].should eq("no_such_user")
      json("tokens:create", "--user", "1")["error"]["code"].should eq("missing_argument")
      json("tokens:create", "--user", "one", "--name", "x")["error"]["code"].should eq("invalid_id")
      run("tokens:create", "--user", "1", "--name")[0].should eq(2)
    end
  end

  it "needs a database" do
    ENV["PUNCH_STORAGE"] = File.tempname("punch-none")
    begin
      json("tokens")["error"]["code"].should eq("no_database")
    ensure
      ENV.delete("PUNCH_STORAGE")
    end
  end
end

describe "punch sessions" do
  it "lists live sessions and ends one, or all of a user's" do
    with_storage do |storage|
      database = Punch::Database.open(File.join(storage, "primary.db"))
      begin
        ids = [1, 1, 2].map do |user|
          database.write { |db| Punch::Auth::Sessions.create(db, user.to_i64, "password", ip: "203.0.113.7", user_agent: "Spec") }[0].id
        end
      ensure
        database.close
      end
      json("sessions")["sessions"].as_a.size.should eq(3)
      text = run("sessions", "--user", "1")[1]
      text.lines.size.should eq(2)
      text.should contain("password")
      text.should contain("203.0.113.7")

      json("sessions:revoke", ids[0].to_s).should eq(JSON.parse(%({"revoked": 1})))
      json("sessions:revoke", ids[0].to_s)["error"]["code"].should eq("not_found")
      run("sessions:revoke", "--user", "1")[1].should eq("Ended 1 session.\n")
      json("sessions")["sessions"].as_a.map(&.["user_id"]).should eq([2])
      json("sessions:revoke")["error"]["code"].should eq("missing_argument")
    end
  end
end

describe "punch passwords and identities" do
  it "counts stored hashes by parameters and lists a user's identities" do
    with_storage do |storage|
      json("passwords").should eq(JSON.parse(%({"algorithm": "pbkdf2-sha256", "iterations": 1000, "threads": 2, "queue": 64, "stored": {}})))
      run("passwords")[1].should contain("No stored passwords.")
      database = Punch::Database.open(File.join(storage, "primary.db"))
      begin
        database.write do |db|
          Punch::Auth::EmailIdentities.add(db, 1, Punch::Email.parse("ada@example.org").as(Punch::Email), verified_at: Time.utc)
          Punch::Auth::Passwords.set(db, 1, Punch::Auth::Passwords.hash_now("correct horse battery"))
          Punch::Auth::Passwords.set(db, 2, Punch::Auth::Passwords.hash_now("correct horse battery", 500))
        end
      ensure
        database.close
      end
      json("passwords")["stored"].should eq(JSON.parse(%({"pbkdf2-sha256 i=1000": 1, "pbkdf2-sha256 i=500": 1})))
      text = run("passwords")[1]
      text.should contain("1  pbkdf2-sha256 i=500  (rehashed at the next sign-in)")
      text.should_not contain("$pbkdf2")

      listed = json("identities", "--user", "1")
      listed["identities"].as_a.map(&.["email"]).should eq(["ada@example.org"])
      listed["password"].as_bool.should be_true
      run("identities", "--user", "1")[1].should contain("ada@example.org  verified ")
      json("identities", "--user", "2")["identities"].as_a.should be_empty
      json("identities")["error"]["code"].should eq("missing_argument")
    end
  end
end
