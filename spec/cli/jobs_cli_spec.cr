require "../spec_helper"
require "../../src/punch/cli"

module JobsCLISpec
  # The value, or the example fails: for IDs and rows that must exist.
  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end

  struct Export
    include Punch::Job

    getter report_id : Int64

    def initialize(@report_id)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  @[Punch::Payloads::Version(3, from: {2 => V2})]
  struct Archive
    include Punch::Job

    getter report_id : Int64

    def initialize(@report_id)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end

    struct V2
      include Punch::Payloads::Frozen

      getter report : Int64

      def upgrade : Archive
        Archive.new(report)
      end
    end
  end
end

private def run(*args : String) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::APP_COMMANDS)
  {code, stdout.to_s, stderr.to_s}
end

private def json(*args : String) : JSON::Any
  JSON.parse(run(*args, "--json")[1])
end

# A storage directory whose queue.db holds a done, a failed, a ready, and a
# scheduled job, as PUNCH_STORAGE for the block. Yields the IDs in that
# order.
private def with_queue(&)
  storage = File.tempname("punch-jobs-cli")
  Dir.mkdir(storage)
  database = Punch::Database.open(File.join(storage, "queue.db"), name: "queue")
  queue = Punch::Job::Queue.new(database)
  done = JobsCLISpec.must(queue.enqueue(JobsCLISpec::Export.new(1)))
  failed = JobsCLISpec.must(queue.enqueue(JobsCLISpec::Export.new(2)))
  claimed = queue.claim("p", 2, Punch::Job::Queue::Registry.types)
  queue.finish(claimed.find!(&.id.==(done)), "p")
  queue.fail(claimed.find!(&.id.==(failed)), "p", "Boom: it broke\n  at somewhere")
  ready = JobsCLISpec.must(queue.enqueue(JobsCLISpec::Export.new(3)))
  scheduled = JobsCLISpec.must(queue.enqueue(JobsCLISpec::Export.new(4), in: 1.hour))
  queue.heartbeat("host:1:abcd", "jobs", ["default"])
  database.close
  ENV["PUNCH_STORAGE"] = storage
  yield done, failed, ready, scheduled
ensure
  ENV.delete("PUNCH_STORAGE")
  FileUtils.rm_rf(storage) if storage
end

describe "punch jobs:list" do
  it "lists jobs newest first, filtered by state, queue, and type" do
    with_queue do |done, failed, ready, scheduled|
      json("jobs:list")["jobs"].as_a.map(&.["id"].as_i64).should eq([scheduled, ready, failed, done])
      json("jobs:list", "--state", "failed")["jobs"].as_a.map(&.["id"].as_i64).should eq([failed])
      json("jobs:list", "--state", "scheduled")["jobs"].as_a.map(&.["state"].as_s).should eq(["scheduled"])
      json("jobs:list", "--state", "ready")["jobs"].as_a.map(&.["id"].as_i64).should eq([ready])
      json("jobs:list", "--queue", "mail")["jobs"].as_a.should be_empty
      json("jobs:list", "--type", "JobsCLISpec::Export", "--limit", "1")["jobs"].as_a.size.should eq(1)
      job = json("jobs:list", "--state", "failed")["jobs"][0]
      job["type"].should eq("JobsCLISpec::Export")
      job["error"].as_s.should start_with("Boom")
      code, stdout, _ = run("jobs:list")
      code.should eq(0)
      stdout.should contain("scheduled")
      stdout.should contain("Boom: it broke")
      run("jobs:list", "--state", "lost")[0].should eq(2)
      run("jobs:list", "--limit", "0")[0].should eq(2)
      run("jobs:list", "--state")[0].should eq(2)
    end
  end

  it "fails without a queue.db" do
    ENV["PUNCH_STORAGE"] = File.tempname("punch-jobs-none")
    json("jobs:list")["error"]["code"].should eq("no_database")
  ensure
    ENV.delete("PUNCH_STORAGE")
  end
end

describe "punch jobs:show" do
  it "shows one job with its payload and error" do
    with_queue do |_, failed|
      job = json("jobs:show", failed.to_s)
      job["payload"].should eq(JSON.parse(%({"report_id": 2})))
      job["state"].should eq("failed")
      job["attempts"].should eq(1)
      run("jobs:show", failed.to_s)[1].should contain("at somewhere")
      json("jobs:show", "999")["error"]["code"].should eq("not_found")
      run("jobs:show", "x")[0].should eq(2)
    end
  end
end

describe "punch jobs:stats" do
  it "counts jobs per queue and state and lists worker processes" do
    with_queue do
      report = json("jobs:stats")
      report["counts"].as_a.map { |count| {count["state"].as_s, count["jobs"].as_i} }.sort!.should eq(
        [{"done", 1}, {"failed", 1}, {"ready", 1}, {"scheduled", 1}])
      report["processes"].as_a.map(&.["id"].as_s).should eq(["host:1:abcd"])
      run("jobs:stats")[1].should contain("Worker processes:")
    end
  end
end

describe "punch jobs:retry and jobs:discard" do
  it "retries a failed job and discards a waiting one" do
    with_queue do |done, failed, ready|
      json("jobs:retry", failed.to_s).should eq(JSON.parse(%({"id": #{failed}, "state": "ready"})))
      json("jobs:retry", done.to_s)["error"]["code"].should eq("not_retryable")
      json("jobs:discard", ready.to_s).should eq(JSON.parse(%({"id": #{ready}, "state": "discarded"})))
      json("jobs:discard", done.to_s)["error"]["code"].should eq("not_discardable")
      json("jobs:show", ready.to_s)["error"].should eq("discarded by hand")
    end
  end
end

describe "punch jobs:versions" do
  it "counts unfinished jobs and outbox entries per payload version" do
    with_queue do
      storage = ENV["PUNCH_STORAGE"]
      database = Punch::Database.open(File.join(storage, "queue.db"), name: "queue")
      queue = Punch::Job::Queue.new(database)
      {1, 2, 2, 4}.each do |version|
        queue.insert(Punch::Job::Queue::Entry.new("default", "JobsCLISpec::Archive", version, "{}", 0, Time.utc, 10))
      end
      queue.insert(Punch::Job::Queue::Entry.new("default", "Gone::Job", 1, "{}", 0, Time.utc, 10))
      database.close
      primary = Punch::Database.open(File.join(storage, "primary.db"), name: "primary")
      primary.write { |db| Punch::Job::Outbox.sql.split(";").map(&.strip).reject(&.empty?).each { |sql| db.exec(sql) } }
      primary.write { |db| Punch::Job::Outbox.add(db, Punch::Job::Queue.entry(JobsCLISpec::Archive.new(5), Time.utc)) }
      primary.close

      types = json("jobs:versions")["types"].as_a.to_h { |type| {type["type"].as_s, type} }
      archive = types["JobsCLISpec::Archive"]
      {archive["version"], archive["reads"]}.should eq({3, [3, 2]})
      archive["versions"].as_a.map { |version| {version["version"].as_i, version["readable"].as_bool, version["jobs"].as_i, version["outbox"].as_i} }.should eq([
        {1, false, 1, 0}, {2, true, 2, 0}, {3, true, 0, 1}, {4, false, 1, 0},
      ])
      types["Gone::Job"]["known"].should be_false
      types["JobsCLISpec::Export"]["versions"][0]["states"].should eq(JSON.parse(%({"failed": 1, "ready": 2})))

      text = run("jobs:versions")[1]
      text.should contain("JobsCLISpec::Archive  version 3, reads 3, 2")
      text.should contain("  version 1: 1 job (ready 1); nothing here reads it: parked when claimed")
      text.should contain("  version 2: 2 jobs (ready 2)")
      text.should contain("  version 3: 0 jobs, 1 in the outbox")
      text.should contain("  version 4: 1 job (ready 1); newer than this binary reads")
      text.should contain("Gone::Job  not a job type of this binary")
    end
  end
end
