require "../spec_helper"
require "../support/auth_schema"

private NOW = Time.utc(2026, 10, 9, 12, 0, 0)

private def count(database : Punch::Database, table : String) : Int64
  database.read(&.query_one?("SELECT count(*) FROM #{table}", &.read(Int64))) || 0_i64
end

describe Punch::Auth::Token do
  it "makes 43 base62 characters of 256 bits, different every time" do
    tokens = Array.new(1000) { Punch::Auth::Token.generate }
    tokens.uniq.size.should eq(1000)
    tokens.each { |token| Punch::Auth::Token.well_formed?(token).should be_true }
    # Every character of the alphabet turns up.
    tokens.join.chars.uniq!.size.should eq(62)
    Punch::Auth::Token.digest(tokens.first).size.should eq(32)
  end

  it "refuses anything else before a lookup" do
    token = Punch::Auth::Token.generate
    {token[0, 42], token + "a", token.sub(token[0], '-'), token.sub(token[5], 'ä'), ""}.each do |bad|
      Punch::Auth::Token.well_formed?(bad).should be_false
    end
  end
end

describe Punch::Auth::Sessions do
  it "stores only the digest of the cookie value, and finds the session by it" do
    AuthSchema.database do |database|
      session, token = database.write { |db| Punch::Auth::Sessions.create(db, 1, "password", now: NOW, ip: "203.0.113.9", user_agent: "Spec/1.0") }
      session.user_id.should eq(1)
      session.method.should eq("password")
      session.expires_at.should eq(NOW + 30.days)
      session.ip.should eq("203.0.113.9")
      token.to_s.should eq("[REDACTED]")

      stored = database.read(&.query_one?("SELECT token_hash FROM punch_sessions", &.read(Bytes)))
      stored.should eq(Punch::Auth::Token.digest(token.unwrap))
      everything = "CAST(token_hash AS TEXT) || method || authenticated_at || created_at || expires_at || ip || user_agent"
      database.read(&.query_one?("SELECT count(*) FROM punch_sessions WHERE instr(#{everything}, ?) > 0", token.unwrap, &.read(Int64))).should eq(0)

      database.read { |db| Punch::Auth::Sessions.find(db, token.unwrap, now: NOW + 1.minute) }.try(&.id).should eq(session.id)
      database.read { |db| Punch::Auth::Sessions.find(db, Punch::Auth::Token.generate, now: NOW) }.should be_nil
      database.read { |db| Punch::Auth::Sessions.find(db, "nonsense", now: NOW) }.should be_nil
    end
  end

  it "ends a session after the idle timeout and after its lifetime, whatever comes first" do
    AuthSchema.database do |database|
      config = Punch::Auth::Config.new(session_idle_timeout: 1.day, session_lifetime: 3.days)
      _, token = database.write { |db| Punch::Auth::Sessions.create(db, 1, "password", now: NOW, config: config) }
      find = ->(at : Time) { database.read { |db| Punch::Auth::Sessions.find(db, token.unwrap, now: at, config: config) } }

      find.call(NOW + 23.hours).should_not be_nil
      find.call(NOW + 1.day).should be_nil
      # Used every 20 hours, it stays alive until its lifetime ends.
      at = NOW
      while (at += 20.hours) < NOW + 3.days
        session = find.call(at).should_not be_nil
        database.write { |db| Punch::Auth::Sessions.touch(db, session, now: at) }
      end
      find.call(NOW + 3.days - 1.second).should_not be_nil
      find.call(NOW + 3.days).should be_nil
    end
  end

  it "is due for a last-seen write only after the touch interval" do
    AuthSchema.database do |database|
      session, _ = database.write { |db| Punch::Auth::Sessions.create(db, 1, "password", now: NOW) }
      session.touch_due?(NOW + 4.minutes).should be_false
      session.touch_due?(NOW + 5.minutes).should be_true
    end
  end

  it "renews the cookie value, keeping when the user signed in unless they proved it again" do
    AuthSchema.database do |database|
      session, old = database.write { |db| Punch::Auth::Sessions.create(db, 1, "password", now: NOW) }
      renewed, new = database.write { |db| Punch::Auth::Sessions.renew(db, session, now: NOW + 1.hour) }.should_not be_nil
      renewed.id.should eq(session.id)
      renewed.authenticated_at.should eq(NOW)
      renewed.last_seen_at.should eq(NOW + 1.hour)
      database.read { |db| Punch::Auth::Sessions.find(db, old.unwrap, now: NOW + 1.hour) }.should be_nil
      database.read { |db| Punch::Auth::Sessions.find(db, new.unwrap, now: NOW + 1.hour) }.should_not be_nil

      again, _ = database.write { |db| Punch::Auth::Sessions.renew(db, renewed, method: "password+totp", now: NOW + 2.hours) }.should_not be_nil
      again.method.should eq("password+totp")
      again.authenticated_at.should eq(NOW + 2.hours)
    end
  end

  it "lists, revokes one, revokes all but one, and purges" do
    AuthSchema.database do |database|
      a, _ = database.write { |db| Punch::Auth::Sessions.create(db, 1, "password", now: NOW) }
      b, _ = database.write { |db| Punch::Auth::Sessions.create(db, 1, "magic_link", now: NOW + 1.minute) }
      c, _ = database.write { |db| Punch::Auth::Sessions.create(db, 1, "password", now: NOW + 2.minutes) }
      database.write { |db| Punch::Auth::Sessions.create(db, 2, "password", now: NOW) }

      database.read { |db| Punch::Auth::Sessions.list(db, 1, now: NOW + 3.minutes) }.map(&.id).should eq([c.id, b.id, a.id])
      database.read { |db| Punch::Auth::Sessions.list(db, now: NOW + 3.minutes) }.size.should eq(4)

      database.write { |db| Punch::Auth::Sessions.revoke(db, a.id) }.should be_true
      database.write { |db| Punch::Auth::Sessions.revoke(db, a.id) }.should be_false
      database.write { |db| Punch::Auth::Sessions.revoke_all(db, 1, except: c.id) }.should eq(1)
      database.read { |db| Punch::Auth::Sessions.list(db, 1, now: NOW + 3.minutes) }.map(&.id).should eq([c.id])

      database.write { |db| Punch::Auth::Sessions.purge(db, now: NOW + 8.days) }.should eq(2)
      count(database, "punch_sessions").should eq(0)
    end
  end

  it "goes with its user" do
    AuthSchema.database do |database|
      database.write { |db| Punch::Auth::Sessions.create(db, 1, "password", now: NOW) }
      database.write(&.exec("DELETE FROM users WHERE id = 1"))
      count(database, "punch_sessions").should eq(0)
    end
  end

  it "refuses a sign-in method that is not a short name" do
    AuthSchema.database do |database|
      expect_raises(ArgumentError, /sign-in method/) do
        database.write { |db| Punch::Auth::Sessions.create(db, 1, "Pass word", now: NOW) }
      end
    end
  end
end

describe Punch::Auth::APITokens do
  it "shows the token once and keeps its digest; prefix, length, and checksum are checked before a lookup" do
    AuthSchema.database do |database|
      config = Punch::Auth::Config.new(token_prefix: "inv")
      created = database.write { |db| Punch::Auth::APITokens.create(db, 1, " CI deploy ", NOW + 30.days, now: NOW, config: config) }
      row, secret = created.as({Punch::Auth::APIToken, Punch::Secret(String)})
      row.name.should eq("CI deploy")
      row.last_used_at.should be_nil
      token = secret.unwrap
      token.should match(/\Ainv_[0-9A-Za-z]{49}\z/)
      Punch::Auth::APITokens.well_formed?(token, "inv").should be_true

      database.read { |db| Punch::Auth::APITokens.find(db, token, now: NOW, config: config) }.try(&.id).should eq(row.id)
      # One changed character breaks the checksum, so nothing is looked up.
      changed = token.sub(10, token[10] == 'a' ? 'b' : 'a')
      Punch::Auth::APITokens.well_formed?(changed, "inv").should be_false
      Punch::Auth::APITokens.well_formed?(token, "punch").should be_false
      Punch::Auth::APITokens.well_formed?(token.sub("inv_", "inv-"), "inv").should be_false
      trace = Punch::Spec.trace { database.read { |db| Punch::Auth::APITokens.find(db, changed, now: NOW, config: config) }.should be_nil }
      trace.spans.none?(&.name.starts_with?("Punch::Auth::APITokens")).should be_true
      # A well-formed token that was never issued is looked up and not found.
      database.read { |db| Punch::Auth::APITokens.find(db, Punch::Auth::APITokens.generate("inv"), now: NOW, config: config) }.should be_nil
    end
  end

  it "always expires, within the maximum lifetime" do
    AuthSchema.database do |database|
      create = ->(expires : Time, name : String) { database.write { |db| Punch::Auth::APITokens.create(db, 1, name, expires, now: NOW) } }
      create.call(NOW, "x").as(Punch::Invalid).code.should eq("out_of_range")
      create.call(NOW + 367.days, "x").as(Punch::Invalid).params["max_days"].should eq(366)
      create.call(NOW + 1.day, "  ").as(Punch::Invalid).code.should eq("blank")
      create.call(NOW + 1.day, "x" * 101).as(Punch::Invalid).code.should eq("too_long")

      _, secret = create.call(NOW + 1.day, "short").as({Punch::Auth::APIToken, Punch::Secret(String)})
      database.read { |db| Punch::Auth::APITokens.find(db, secret.unwrap, now: NOW + 1.day - 1.second) }.should_not be_nil
      database.read { |db| Punch::Auth::APITokens.find(db, secret.unwrap, now: NOW + 1.day) }.should be_nil
      database.write { |db| Punch::Auth::APITokens.purge(db, now: NOW + 1.day) }.should eq(1)
    end
  end

  it "records use, lists without secrets, and revokes, also only for its owner" do
    AuthSchema.database do |database|
      token, _ = database.write { |db| Punch::Auth::APITokens.create(db, 1, "a", NOW + 5.days, now: NOW) }.as({Punch::Auth::APIToken, Punch::Secret(String)})
      token.touch_due?(NOW).should be_true
      used = database.write { |db| Punch::Auth::APITokens.touch(db, token, now: NOW + 1.hour) }
      used.touch_due?(NOW + 1.hour + 4.minutes).should be_false
      listed = database.read { |db| Punch::Auth::APITokens.list(db, 1, now: NOW + 2.hours) }
      listed.map(&.last_used_at).should eq([NOW + 1.hour])
      listed.to_json.should_not contain("token_hash")

      database.write { |db| Punch::Auth::APITokens.revoke(db, token.id, user_id: 2) }.should be_false
      database.write { |db| Punch::Auth::APITokens.revoke(db, token.id, user_id: 1) }.should be_true
      database.read { |db| Punch::Auth::APITokens.list(db, now: NOW) }.should be_empty
    end
  end
end

describe Punch::Auth::OneTimeTokens do
  it "works once, for its purpose, until it expires" do
    AuthSchema.database do |database|
      token = database.write { |db| Punch::Auth::OneTimeTokens.issue(db, "password_reset", 1.hour, user_id: 1, now: NOW) }.unwrap
      database.read { |db| Punch::Auth::OneTimeTokens.find(db, "email_verification", token, now: NOW) }.should be_nil
      found = database.read { |db| Punch::Auth::OneTimeTokens.find(db, "password_reset", token, now: NOW + 59.minutes) }.should_not be_nil
      found.user_id.should eq(1)

      database.write { |db| Punch::Auth::OneTimeTokens.consume(db, "email_verification", token, now: NOW) }.should be_nil
      used = database.write { |db| Punch::Auth::OneTimeTokens.consume(db, "password_reset", token, now: NOW + 1.minute) }.should_not be_nil
      used.expires_at.should eq(NOW + 1.hour)
      database.write { |db| Punch::Auth::OneTimeTokens.consume(db, "password_reset", token, now: NOW + 2.minutes) }.should be_nil

      late = database.write { |db| Punch::Auth::OneTimeTokens.issue(db, "magic_link", 10.minutes, subject: "ada@example.org", now: NOW) }.unwrap
      database.write { |db| Punch::Auth::OneTimeTokens.consume(db, "magic_link", late, now: NOW + 10.minutes) }.should be_nil
      count(database, "punch_one_time_tokens").should eq(0)
    end
  end

  it "keeps the subject it vouches for, withdraws older tokens, and purges expired ones" do
    AuthSchema.database do |database|
      database.write { |db| Punch::Auth::OneTimeTokens.issue(db, "password_reset", 1.hour, user_id: 1, now: NOW) }
      database.write { |db| Punch::Auth::OneTimeTokens.issue(db, "password_reset", 1.hour, user_id: 2, now: NOW) }
      check = database.write { |db| Punch::Auth::OneTimeTokens.issue(db, "email_verification", 1.day, user_id: 1, subject: "ada@example.org", now: NOW) }.unwrap
      database.write { |db| Punch::Auth::OneTimeTokens.revoke_all(db, "password_reset", 1) }.should eq(1)
      database.write { |db| Punch::Auth::OneTimeTokens.purge(db, now: NOW + 2.hours) }.should eq(1)
      database.write { |db| Punch::Auth::OneTimeTokens.consume(db, "email_verification", check, now: NOW + 2.hours) }.try(&.subject).should eq("ada@example.org")
    end
  end

  it "refuses a purpose that is not a short name" do
    AuthSchema.database do |database|
      expect_raises(ArgumentError, /purpose/) { database.write { |db| Punch::Auth::OneTimeTokens.issue(db, "Reset!", 1.hour) } }
    end
  end
end

describe Punch::Auth::Schema do
  it "finds nothing missing in the tables it documents" do
    AuthSchema.database { |database| Punch::Auth::Schema.problems(database).should be_empty }
  end

  it "names each missing table and column" do
    Punch::Spec.database do |database|
      Punch::Migrations::Schema.load(database, <<-SQL, "partial")
        CREATE TABLE punch_sessions (id INTEGER PRIMARY KEY, token_hash TEXT NOT NULL) STRICT;
        SQL
      problems = Punch::Auth::Schema.problems(database)
      problems.should contain("punch_sessions.token_hash is TEXT, Punch needs BLOB")
      problems.should contain("punch_sessions.user_id is missing (lib/punch/docs/auth.md)")
      problems.should contain("table punch_api_tokens is missing; add it with a migration (lib/punch/docs/auth.md)")
    end
  end
end

describe Punch::Auth::Config do
  it "refuses settings that cannot work" do
    expect_raises(ArgumentError, /token_prefix/) { Punch::Auth::Config.new(token_prefix: "In_v") }
    expect_raises(ArgumentError, /session_lifetime/) { Punch::Auth::Config.new(session_idle_timeout: 2.days, session_lifetime: 1.day) }
    expect_raises(ArgumentError, /touch_interval/) { Punch::Auth::Config.new(session_idle_timeout: 1.minute) }
  end
end
