require "../spec_helper"
require "../../src/punch/cli"

module JobsTypesCLISpec
  struct Placed
    include Punch::Event

    getter order_id : Int64

    def initialize(@order_id)
    end
  end

  @[Punch::Job::Recurring(cron: "0 3 * * *")]
  @[Punch::Job::Options(queue: "nightly", priority: 5)]
  struct Nightly
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Concurrency(1, by: :order_id)]
  struct Ship
    include Punch::Subscriber(Placed)

    def call(event : Placed, job : Punch::Job::Context) : Punch::Job::Result
    end
  end
end

private def run(*args : String) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::APP_COMMANDS)
  {code, stdout.to_s, stderr.to_s}
end

describe "punch jobs:types" do
  it "lists job types and deferred subscribers with options, limits, and schedules" do
    types = JSON.parse(run("jobs:types", "--json")[1])["types"].as_a.to_h { |type| {type["type"].as_s, type} }
    nightly = types["JobsTypesCLISpec::Nightly"]
    {nightly["queue"], nightly["priority"], nightly["schedule"], nightly["version"], nightly["reads"]}.should eq({"nightly", 5, "cron 0 3 * * *", 1, [1]})
    Time.parse_rfc3339(nightly["next_run"].as_s).hour.should eq(3)
    ship = types["JobsTypesCLISpec::Ship(JobsTypesCLISpec::Placed)"]
    {ship["concurrency"], ship["concurrency_limit"], ship["schedule"]}.should eq({"JobsTypesCLISpec::Ship by order_id", 1, nil})
    types.has_key?("Punch::Job::Queue::Purge").should be_true
    run("jobs:types")[1].should contain("cron 0 3 * * *, next")
  end
end

describe "punch jobs:pause and jobs:resume" do
  it "pauses and resumes a queue for every process" do
    storage = File.tempname("punch-jobs-pause")
    Dir.mkdir(storage)
    database = Punch::Database.open(File.join(storage, "queue.db"), name: "queue")
    Punch::Job::Queue.new(database)
    database.close
    ENV["PUNCH_STORAGE"] = storage
    JSON.parse(run("jobs:pause", "mail", "--json")[1]).should eq(JSON.parse(%({"queue": "mail", "paused": true, "changed": true})))
    JSON.parse(run("jobs:pause", "mail", "--json")[1])["changed"].should be_false
    JSON.parse(run("jobs:stats", "--json")[1])["paused"].should eq(JSON.parse(%(["mail"])))
    JSON.parse(run("jobs:resume", "mail", "--json")[1])["paused"].should be_false
    run("jobs:pause", "Mail")[0].should eq(2)
    run("jobs:pause")[0].should eq(2)
  ensure
    ENV.delete("PUNCH_STORAGE")
    FileUtils.rm_rf(storage) if storage
  end
end
