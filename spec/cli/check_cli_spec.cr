require "../spec_helper"
require "../support/app_fixture"
require "../../src/punch/cli/tool"

private def check(args : Array(String) = [] of String) : Punch::CLI::Report | Punch::CLI::Failure
  command = Punch::CLI::Commands::Check.new(Punch::CLI::TOOL_COMMANDS)
  command.progress = nil
  command.run(args)
end

private def statuses(steps : Array(Punch::CLI::Commands::Check::Step)) : Hash(String, String)
  steps.to_h { |step| {step.name, step.status.to_s.downcase} }
end

# The tiny app with a spec and Ameba. Ameba with Punch's rules takes a
# minute to build in release mode, so the copy reuses this repository's
# `bin/ameba` when `punch check` has built it.
private def in_tiny_app(& : ->) : Nil
  AppFixture.copy("spec/cli/fixture/tiny", shards: %w[ameba]) do
    Dir.mkdir("spec")
    File.write("spec/tiny_spec.cr", %(require "spec"\n\ndescribe "tiny" do\n  it "adds" do\n    (1 + 1).should eq(2)\n  end\nend\n))
    if File.exists?("#{AppFixture::ROOT}/bin/ameba")
      Dir.mkdir_p(Punch::CLI::Commands::Check::AMEBA_DIRECTORY)
      File.symlink("#{AppFixture::ROOT}/bin/ameba", "#{Punch::CLI::Commands::Check::AMEBA_DIRECTORY}/ameba")
    end
    yield
  end
end

describe Punch::CLI::Commands::Check do
  it "runs every step that applies and passes a clean app" do
    in_tiny_app do
      outcome = check
      fail outcome.message if outcome.is_a?(Punch::CLI::Failure)
      result = outcome.as(Punch::CLI::Commands::Check::Result)
      statuses(result.steps).should eq({"format" => "passed", "schema" => "skipped", "punchtables" => "skipped", "migrations" => "skipped", "queries" => "skipped", "explain" => "skipped", "i18n" => "skipped", "requires" => "skipped", "unreached" => "skipped", "docs" => "skipped", "lint" => "passed",
                                        "build" => "passed", "creds" => "skipped", "limits" => "skipped", "policies" => "skipped", "events" => "skipped", "webhooks" => "skipped", "jobs" => "skipped", "boot" => "skipped", "payloads" => "skipped", "openapi" => "skipped", "specs" => "passed", "nocache" => "passed"})
      result.steps.find!(&.name.== "specs").detail.should eq("1 examples, 0 failures, 0 errors, 0 pending (CRYSTAL_WORKERS=4)")
      result.steps.find!(&.name.== "nocache").detail.should eq("1 examples, 0 failures, 0 errors, 0 pending (PUNCH_CACHE=off CRYSTAL_WORKERS=4)")
      File.exists?("bin/tiny").should be_true
      File.exists?("bin/tiny.next").should be_false
    end
  end

  it "runs every step after a failure and reports each failure with its output" do
    in_tiny_app do
      File.write("src/tiny.cr", File.read("src/tiny.cr").sub(%(MESSAGE = "one"), %(MESSAGE =   "one")))
      File.write("spec/tiny_spec.cr", File.read("spec/tiny_spec.cr").sub("eq(2)", "eq(3)"))
      failure = check.as(Punch::CLI::Failure)
      failure.code.should eq("check_failed")
      failure.message.should start_with("3 checks failed: format, lint, specs\n\n== format\nformatting './src/tiny.cr' produced changes")
      failure.message.should contain("== specs\n")
      failure.message.should contain("Expected: 3")
      steps = failure.details.try(&.["steps"].as_a) || fail "no details"
      steps.to_h { |step| {step["name"].as_s, step["status"].as_s} }["build"].should eq("passed")
    end
  end

  it "fails the lint step with a way out when the app has no Ameba" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      failure = check.as(Punch::CLI::Failure)
      failure.message.should start_with("1 check failed: lint\n\n== lint\nAmeba is not installed. Add it to development_dependencies")
    end
  end

  it "fails the creds step on a committed or unignored key and on a file its key does not open" do
    in_tiny_app do
      git = ->(args : Array(String)) { Process.run("git", args, output: Process::Redirect::Close, error: Process::Redirect::Close).success?.should be_true }
      git.call(%w[init -q])
      Punch::CLI.run(%w[creds:init --env production], IO::Memory.new, IO::Memory.new)
      Punch::CLI.run(%w[creds:init --env test], IO::Memory.new, IO::Memory.new)
      git.call(%w[add -f config/credentials/production.key])
      File.write(".gitignore", "")
      File.write("config/credentials/test.yml.enc", File.read("config/credentials/production.yml.enc"))
      failure = check.as(Punch::CLI::Failure)
      failure.message.should start_with("1 check failed: creds\n\n== creds\n")
      failure.message.should contain("config/credentials/production.key is committed. Remove it (git rm --cached config/credentials/production.key), then run 'punch creds:rekey'")
      failure.message.should contain("config/credentials/test.key is not ignored by git; add /config/credentials/*.key to .gitignore.")
      failure.message.should contain("config/credentials/test.yml.enc was encrypted with another key than config/credentials/test.key")
    end
  end

  it "fails the unreached step on an app file no target requires, naming it" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      Dir.mkdir_p("app/billing/reports/operations")
      Dir.mkdir_p("db")
      File.write("app/wired.cr", "WIRED = 1\n")
      File.write("app/billing/reports/operations/summary.cr", "SUMMARY = 1\n")
      File.write("db/columns.cr", "COLUMNS = 1\n")
      File.write("src/tiny.cr", %(require "../app/wired"\nrequire "../db/columns"\n) + File.read("src/tiny.cr"))
      failure = check.as(Punch::CLI::Failure)
      steps = failure.details.try(&.["steps"].as_a) || fail "no details"
      found = steps.find! { |candidate| candidate["name"] == "unreached" }
      found["status"].should eq("failed")
      found["detail"].as_s.should contain("app/billing/reports/operations/summary.cr: require it")
      found["detail"].as_s.should_not contain("wired.cr")
      found["detail"].as_s.should_not contain("columns.cr")
      File.write("src/tiny.cr", %(require "../app/billing/reports/operations/summary"\n) + File.read("src/tiny.cr"))
      outcome = check.as(Punch::CLI::Failure)
      steps = outcome.details.try(&.["steps"].as_a) || fail "no details"
      steps.find! { |candidate| candidate["name"] == "unreached" }["status"].should eq("passed")
    end
  end

  it "fails the punchtables step when Punch's table in db/schema.sql lacks a column, naming the migration" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      Dir.mkdir_p("db")
      File.write("db/schema.sql", Punch::Job::Steps::Progress.sql + Punch::Job::Outbox.sql.sub("traceparent       TEXT,", ""))
      failure = check.as(Punch::CLI::Failure)
      steps = failure.details.try(&.["steps"].as_a) || fail "no details"
      found = steps.find! { |candidate| candidate["name"] == "punchtables" }
      found["status"].should eq("failed")
      found["detail"].as_s.should contain("punch_outbox.traceparent is missing")
      found["detail"].as_s.should contain("punch db:migration --punch outbox")
      File.write("db/schema.sql", Punch::Job::Steps::Progress.sql + Punch::Job::Outbox.sql)
      steps = check.as(Punch::CLI::Failure).details.try(&.["steps"].as_a) || fail "no details"
      steps.find! { |candidate| candidate["name"] == "punchtables" }["status"].should eq("passed")
    end
  end

  it "takes --base for the OpenAPI diff and nothing else" do
    check(["--base"]).as(Punch::CLI::Failure).code.should eq("missing_argument")
    check(["--fast"]).as(Punch::CLI::Failure).code.should eq("unexpected_argument")
  end
end

describe "punch check, limits step" do
  route = ->(operation : String, kind : String, actor : String, limits : Int32, exempt : String?) do
    JSON.parse({method: "POST", path: "/x", operation: operation, kind: kind, actor: actor,
                rate_limits: Array.new(limits) { {name: "x"} }, rate_limit_exempt: exempt}.to_json)
  end

  it "requires a limit or an exemption on Commands without a required user" do
    ok, detail = Punch::CLI::Commands::Check.rate_limits([
      route.call("Accounts::SignIn", "command", "none", 1, nil),
      route.call("Hooks::Receive", "command", "none", 0, "signed"),
      route.call("Billing::Send", "command", "required", 0, nil),
      route.call("Billing::Show", "query", "none", 0, nil),
    ])
    {ok, detail}.should eq({true, "2 commands without a required user limited or exempt; 1 operations limited"})
    ok, detail = Punch::CLI::Commands::Check.rate_limits([
      route.call("Accounts::SignUp", "command", "none", 0, nil),
      route.call("Notes::Like", "command", "optional", 0, nil),
    ])
    ok.should be_false
    detail.should contain("  POST /x  Accounts::SignUp\n  POST /x  Notes::Like")
  end
end

describe "punch check, policies step" do
  route = ->(operation : String, policy : String?, public : Bool) do
    JSON.parse({method: "GET", path: "/x", operation: operation, policy: policy, public: public}.to_json)
  end

  it "requires a policy or the public marker on every operation" do
    ok, detail = Punch::CLI::Commands::Check.policies([
      route.call("Billing::Show", "Billing::Owner", false),
      route.call("Accounts::SignInPage", nil, true),
    ])
    {ok, detail}.should eq({true, "1 operations with a policy, 1 public"})
    ok, detail = Punch::CLI::Commands::Check.policies([
      route.call("Billing::Show", "Billing::Owner", false),
      route.call("Billing::Index", nil, false),
    ])
    ok.should be_false
    detail.should contain("@[Punch::Authorize(Policy)], or @[Punch::Public]")
    detail.should contain("  GET /x  Billing::Index")
    detail.should_not contain("Billing::Show")
  end
end

describe "punch check, webhooks step" do
  provider = ->(name : String, verify : String) { JSON.parse({name: name, verify: verify}.to_json) }

  it "lists providers that do not verify, and never fails" do
    Punch::CLI::Commands::Check.webhooks([] of JSON::Any).should be_nil
    Punch::CLI::Commands::Check.webhooks([provider.call("payments", "edge")]).should eq({true, "1 providers, all verify their deliveries"})
    Punch::CLI::Commands::Check.webhooks([provider.call("payments", "deferred"), provider.call("pings", "none")])
      .should eq({true, "2 providers; not verifying their deliveries (verify: :none): pings"})
  end
end
