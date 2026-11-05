require "../spec_helper"
require "../../src/punch/cli/tool"

module OpsCLISpec
  @[Punch::Job::Options(attempts: 1)]
  struct Export
    include Punch::Job

    getter report_id : Int64

    def initialize(@report_id)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
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

private def failure(message : String) : Exception
  raise KeyError.new(message)
rescue ex
  ex
end

# A storage directory whose ops.db holds two error groups, one with two
# occurrences, as PUNCH_STORAGE for the block. Yields their IDs, the
# twice-seen one first.
private def with_ops(&)
  storage = File.tempname("punch-ops-cli")
  Dir.mkdir(storage)
  database = Punch::Database.open(File.join(storage, "ops.db"), name: "ops")
  store = Punch::Ops::Store.new(database)
  tracer = Punch::Trace::Tracer.new(events: [] of Punch::Trace::EventSink)
  captures = [{"GET /a", "missing a"}, {"GET /a", "missing b"}, {"job Export", "no export"}].map do |name, message|
    root = tracer.start(name)
    root.error(failure(message))
    root.finish
    Punch::Ops::Sink.capture(root) || fail "nothing captured"
  end
  store.store(captures)
  ids = store.errors.map(&.id)
  database.close
  ENV["PUNCH_STORAGE"] = storage
  yield ids[1], ids[0]
ensure
  ENV.delete("PUNCH_STORAGE")
  FileUtils.rm_rf(storage) if storage
end

describe "punch ops:errors" do
  it "lists open errors, resolved ones, or all" do
    with_ops do |twice, once|
      errors = json("ops:errors")["errors"].as_a
      errors.map(&.["id"].as_i64).should eq([once, twice])
      errors[1]["occurrences"].should eq(2)
      errors[1]["message"].should eq("missing b")
      errors[1]["source"].should eq("GET /a")
      code, stdout, _ = run("ops:errors")
      code.should eq(0)
      stdout.should contain("KeyError in job Export")
      run("ops:resolve", once.to_s)[0].should eq(0)
      json("ops:errors")["errors"].as_a.map(&.["id"].as_i64).should eq([twice])
      json("ops:errors", "--resolved")["errors"].as_a.map(&.["id"].as_i64).should eq([once])
      json("ops:errors", "--all", "--limit", "1")["errors"].as_a.size.should eq(1)
      run("ops:errors", "--limit", "0")[0].should eq(2)
    end
  end

  it "answers without ops.db" do
    ENV["PUNCH_STORAGE"] = File.tempname("punch-ops-none")
    begin
      json("ops:errors")["error"]["code"].should eq("no_database")
    ensure
      ENV.delete("PUNCH_STORAGE")
    end
  end
end

describe "punch ops:error" do
  it "shows the backtrace and the latest occurrences" do
    with_ops do |twice, _|
      error = json("ops:error", twice.to_s)
      error["exception"].should eq("KeyError")
      error["backtrace"].as_s.should contain("ops_cli_spec.cr")
      error["latest"].as_a.map(&.["message"].as_s).should eq(["missing b", "missing a"])
      run("ops:error", twice.to_s)[1].should contain("occurrences   2")
      json("ops:error", "999")["error"]["code"].should eq("not_found")
      run("ops:error", "x")[0].should eq(2)
    end
  end
end

describe "punch ops:resolve and ops:reopen" do
  it "change the state once" do
    with_ops do |twice, _|
      json("ops:resolve", twice.to_s).should eq(JSON.parse(%({"id": #{twice}, "state": "resolved"})))
      json("ops:resolve", twice.to_s)["error"]["code"].should eq("wrong_state")
      json("ops:reopen", twice.to_s)["state"].should eq("open")
      json("ops:reopen", twice.to_s)["error"]["code"].should eq("wrong_state")
      json("ops:reopen", "999")["error"]["code"].should eq("not_found")
    end
  end
end

# A storage directory whose queue.db holds a failed and a ready job, and
# whose ops.db holds the failed job's run, a slow request, and stats, as
# PUNCH_STORAGE for the block. Yields the failed job's, the ready job's,
# and the slow request's IDs.
private def with_storage(&)
  storage = File.tempname("punch-ops-cli")
  Dir.mkdir(storage)
  database = Punch::Database.open(File.join(storage, "queue.db"), name: "queue")
  queue = Punch::Job::Queue.new(database)
  failed = queue.enqueue(OpsCLISpec::Export.new(1)).should_not be_nil
  claimed = queue.claim("p", 1, Punch::Job::Queue::Registry.types)
  queue.fail(claimed.first, "p", "Boom: it broke")
  ready = queue.enqueue(OpsCLISpec::Export.new(2)).should_not be_nil
  database.close
  database = Punch::Database.open(File.join(storage, "ops.db"), name: "ops")
  store = Punch::Ops::Store.new(database)
  now = Time.utc
  run = Punch::Ops::Capture.new(now, "job", "job OpsCLISpec::Export", "a" * 32, 12.5, true, failed,
    %({"punch.job.outcome": "failed"}), true, [] of Punch::Ops::RaisedError, [] of String)
  slow = Punch::Ops::Capture.new(now, "request", "GET /reports", "b" * 32, 812.0, false, nil,
    %({"http.route": "/reports", "http.response.status_code": 200}), true, [] of Punch::Ops::RaisedError, [] of String)
  store.store([run, slow])
  tallies = Punch::Ops::Tallies.new
  tallies[{"request", "GET /reports", Punch::Ops.bucket(now)}] = Punch::Ops::Tally.new.tap(&.run(812.0, false)).tap(&.run(4.0, false))
  tallies[{"query", "Reports::Queries.all", Punch::Ops.bucket(now)}] = Punch::Ops::Tally.new.tap(&.run(3.0, false))
  store.store(tallies)
  slow_id = store.slowest(since: now - 1.hour).first.id
  database.close
  ENV["PUNCH_STORAGE"] = storage
  yield failed, ready, slow_id
ensure
  ENV.delete("PUNCH_STORAGE")
  FileUtils.rm_rf(storage) if storage
end

describe "punch ops" do
  it "shows the state at a glance" do
    with_storage do
      overview = json("ops")
      overview["errors"]["open_errors"].should eq(0)
      overview["jobs"]["failed"].should eq(1)
      overview["jobs"]["ready"].should eq(1)
      overview["requests"]["runs"].should eq(2)
      overview["recovering"].should be_false
      run("ops")[1].should contain("jobs        1 ready, 0 scheduled")
    end
  end

  it "says what is not open" do
    storage = File.tempname("punch-ops-empty")
    Dir.mkdir(storage)
    ENV["PUNCH_STORAGE"] = storage
    begin
      json("ops").should eq(JSON.parse(%({"errors": null, "jobs": null, "processes": null, "requests": null, "recovering": false})))
      run("ops")[1].should contain("queue.db is not open")
    ensure
      ENV.delete("PUNCH_STORAGE")
      FileUtils.rm_rf(storage)
    end
  end
end

describe "punch ops:jobs and ops:job" do
  it "show failed jobs by type and one job with its runs" do
    with_storage do |failed, _|
      jobs = json("ops:jobs")
      jobs["failed"].as_a.map { |group| {group["type"], group["count"], group["latest_id"]} }.should eq([{"OpsCLISpec::Export", 1, failed}])
      run("ops:jobs")[1].should contain("1x  OpsCLISpec::Export  latest #{failed}  Boom: it broke")
      job = json("ops:job", failed.to_s)
      job["state"].should eq("failed")
      job["job"]["payload"].as_s.should contain("report_id")
      job["runs"].as_a.map(&.["outcome"]).should eq(["failed"])
      run("ops:job", failed.to_s)[1].should contain("Boom: it broke")
      json("ops:job", "999")["error"]["code"].should eq("not_found")
    end
  end
end

describe "punch ops:retry and ops:discard" do
  it "act as the console's buttons do" do
    with_storage do |failed, ready|
      json("ops:retry", ready.to_s)["error"].should eq(JSON.parse(%({"code": "wrong_state", "message": "Job #{ready} is ready."})))
      json("ops:retry", failed.to_s).should eq(JSON.parse(%({"id": #{failed}, "state": "ready"})))
      json("ops:discard", failed.to_s)["state"].should eq("discarded")
      json("ops:discard", "999")["error"]["code"].should eq("not_found")
      json("ops:retry", "--type", "OpsCLISpec::Export").should eq(JSON.parse(%({"job_type": "OpsCLISpec::Export", "retried": 0})))
      run("ops:retry", "1", "--type", "X")[0].should eq(2)
    end
  end
end

describe "punch ops:performance, ops:slow, and ops:record" do
  it "show time per name, the slowest requests, and one stored event" do
    with_storage do |_, _, slow|
      performance = json("ops:performance")
      performance["kind"].should eq("request")
      performance["window"].should eq("day")
      row = performance["stats"][0]
      {row["name"], row["runs"], row["max_ms"]}.should eq({"GET /reports", 2, 812.0})
      row["p50_ms"].should eq(5.0)
      json("ops:performance", "--kind", "query", "--window", "hour")["stats"].as_a.map(&.["name"]).should eq(["Reports::Queries.all"])
      json("ops:performance", "--kind", "query")["slowest"].raw.should be_nil
      run("ops:performance")[1].should contain("GET /reports")
      run("ops:performance", "--kind", "sql")[0].should eq(2)
      slowest = json("ops:slow")["slowest"].as_a
      slowest.map { |request| {request["record_id"], request["status"], request["duration_ms"]} }.should eq([{slow, 200, 812.0}])
      run("ops:slow")[1].should contain("GET /reports  record #{slow}")
      record = json("ops:record", slow.to_s)
      record["fields"]["http.route"].should eq("/reports")
      run("ops:record", slow.to_s)[1].should contain("http.response.status_code  200")
      json("ops:record", "999")["error"]["code"].should eq("not_found")
    end
  end
end

describe "punch ops --url" do
  it "takes an https address, or http to this machine, and the token from the environment" do
    ENV.delete("PUNCH_OPS_TOKEN")
    json("ops:errors", "--url", "https://app.example.com")["error"]["code"].should eq("missing_token")
    ENV["PUNCH_OPS_TOKEN"] = "pt_secret"
    begin
      json("ops:errors", "--url", "http://app.example.com")["error"]["code"].should eq("insecure_url")
      json("ops:errors", "--url", "https://ops:pw@app.example.com")["error"]["code"].should eq("invalid_url")
      json("ops:errors", "--url", "app.example.com")["error"]["code"].should eq("invalid_url")
      json("ops:errors", "--url")["error"]["code"].should eq("missing_value")
      unreachable = json("ops:errors", "--url", "http://127.0.0.1:1")["error"]
      unreachable["code"].should eq("unreachable")
      unreachable["message"].as_s.should_not contain("pt_secret")
    ensure
      ENV.delete("PUNCH_OPS_TOKEN")
    end
  end
end
