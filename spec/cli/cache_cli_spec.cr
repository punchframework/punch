require "../spec_helper"
require "../../src/punch/cli"

private def run(*args : String) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::APP_COMMANDS)
  {code, stdout.to_s, stderr.to_s}
end

private def json(*args : String) : JSON::Any
  JSON.parse(run(*args, "--json")[1])
end

# A storage directory whose cache.db holds two entries of `rates` (one
# expired) and one of `reports`, as PUNCH_STORAGE for the block.
private def with_cache(&)
  storage = File.tempname("punch-cache-cli")
  Dir.mkdir(storage)
  database = Punch::Database.open(File.join(storage, "cache.db"), name: "cache")
  durable = Punch::Caches::Durable.new(database)
  now = Time.utc
  rates = Punch::Cache(String, Float64).new("rates", ttl: 1.minute, tier: :durable, durable: durable)
  reports = Punch::Cache(Int64, String).new("reports", ttl: 1.hour, tier: :durable, durable: durable)
  durable.put("rates", rates.shape, %("EUR"), "1.1", now - 1.second, now)
  rates.fetch("USD") { 1.0 }
  reports.fetch(1_i64) { "x" * 100 }
  database.close
  ENV["PUNCH_STORAGE"] = storage
  yield storage
ensure
  ENV.delete("PUNCH_STORAGE")
  FileUtils.rm_rf(storage) if storage
end

describe "punch cache:stats" do
  it "lists entries, expired entries, and bytes per store" do
    with_cache do
      report = json("cache:stats")
      report["max_bytes"].should eq(256 * 1024 * 1024)
      stores = report["stores"].as_a.map { |store| {store["store"].as_s, store["entries"].as_i, store["expired"].as_i} }
      stores.should eq([{"rates", 2, 1}, {"reports", 1, 0}])
      report["bytes"].as_i.should eq(report["stores"].as_a.sum(&.["bytes"].as_i))
      code, stdout, _ = run("cache:stats")
      code.should eq(0)
      stdout.should contain("rates")
    end
  end

  it "fails without a cache.db" do
    storage = File.tempname("punch-cache-none")
    ENV["PUNCH_STORAGE"] = storage
    json("cache:stats")["error"]["code"].should eq("no_database")
  ensure
    ENV.delete("PUNCH_STORAGE")
  end
end

describe "punch cache:clear" do
  it "removes expired entries, one store's, or all" do
    with_cache do
      json("cache:clear", "--expired").should eq(JSON.parse(%({"removed": 1})))
      json("cache:clear", "reports").should eq(JSON.parse(%({"removed": 1})))
      json("cache:clear").should eq(JSON.parse(%({"removed": 1})))
      json("cache:stats")["bytes"].should eq(0)
      run("cache:clear", "a", "b")[0].should eq(2)
    end
  end
end
