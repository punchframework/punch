require "../spec_helper"
require "../../src/punch/cli"
require "../routing/rate_limits_spec"

private def run(*args : String) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::APP_COMMANDS)
  {code, stdout.to_s, stderr.to_s}
end

# A storage directory with a cache.db in which one email is limited.
private def with_storage(&)
  storage = File.tempname("punch-limits-cli")
  Dir.mkdir(storage)
  database = Punch::Database.open(File.join(storage, "cache.db"), name: "cache")
  Punch::Caches::Durable.new(database)
  Punch::Routing.routes
  limiter = Punch::RateLimits.find("rate_limits_spec.sign_in.email") || fail "no limit"
  database.write do |db|
    db.exec("INSERT INTO punch_rate_limits (limiter, key, tat) VALUES (?, ?, ?)", limiter.name, "ada@example.org", (Time.utc + 1.hour).to_unix_ns.to_i64)
  end
  database.close
  ENV["PUNCH_STORAGE"] = storage
  yield storage
ensure
  ENV.delete("PUNCH_STORAGE")
  FileUtils.rm_rf(storage) if storage
end

describe "punch limits" do
  it "lists every operation's limits, keys held in cache.db, and exemptions" do
    with_storage do
      code, stdout, _ = run("limits", "--json")
      code.should eq(0)
      report = JSON.parse(stdout)
      email = report["limits"].as_a.find! { |entry| entry["limit"]["name"] == "rate_limits_spec.sign_in.email" }
      {email["operation"], email["limit"]["store"], email["limit"]["period_seconds"], email["keys"]}.should eq({"RateLimitsSpec::SignIn", "durable", 3600.0, 1})
      report["limits"].as_a.find! { |entry| entry["limit"]["name"] == "rate_limits_spec.sign_in.ip" }["keys"].raw.should be_nil
      report["exempt"].as_a.should contain(JSON.parse(%({"operation": "RateLimitsSpec::Hook", "reason": "signed by the provider, which retries"})))
      run("limits")[1].should contain("rate_limits_spec.sign_in.email: 2 per 1h by email (durable)  RateLimitsSpec::SignIn  1 keys held")
    end
  end

  it "resets a durable limit for one key, and refuses memory limits" do
    with_storage do |storage|
      run("limits:reset", "rate_limits_spec.sign_in.email", "ada@example.org", "--json")[0].should eq(0)
      database = Punch::Database.open(File.join(storage, "cache.db"), name: "cache")
      begin
        database.read(&.query_one?("SELECT count(*) FROM punch_rate_limits", &.read(Int64))).should eq(0)
      ensure
        database.close
      end
      code, stdout, _ = run("limits:reset", "rate_limits_spec.sign_in.ip", "--json")
      code.should eq(1)
      JSON.parse(stdout)["error"]["code"].should eq("memory_limit")
      run("limits:reset", "nope", "--json")[0].should eq(1)
      run("limits:reset", "--json")[0].should eq(2)
    end
  end
end
