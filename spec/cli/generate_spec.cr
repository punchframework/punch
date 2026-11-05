require "../spec_helper"
require "../../src/punch/cli/tool"

private alias App = Punch::CLI::New::App
private alias Generate = Punch::CLI::Generate

# A directory holding *app* as `punch new` writes it, before its steps.
private def with_app(app : App = App.new("tally", "Tally"), &)
  root = File.tempname("generate-spec")
  Generate.rendered(app).each do |path, content|
    File.join(root, path).tap do |file|
      Dir.mkdir_p(File.dirname(file))
      File.write(file, content)
    end
  end
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def plan(result : Generate::Plan | Punch::CLI::Failure) : Generate::Plan
  result.as?(Generate::Plan) || fail "expected a plan, got #{result.as(Punch::CLI::Failure).message}"
end

private def failure(result : Generate::Plan | Punch::CLI::Failure) : Punch::CLI::Failure
  result.as?(Punch::CLI::Failure) || fail "expected a failure, got a plan"
end

private def written(plan : Generate::Plan, path : String) : String
  plan.files.find!(&.path.==(path)).content
end

private def schema(root : String, sql : String) : Nil
  Dir.mkdir_p(File.join(root, "db"))
  File.write(File.join(root, "db/schema.sql"), sql)
end

describe Punch::CLI::New::Detect do
  it "reads back the names and the parts punch new was given" do
    app = App.new("time-sheets", "TimeSheets", organizations: true, tokens: false, deploy: "systemd", ci: "none", languages: %w[en de])
    with_app(app) do |root|
      found = Punch::CLI::New::Detect.app(root).as(App)
      found.name.should eq("time-sheets")
      found.module_name.should eq("TimeSheets")
      {found.magic_links?, found.organizations?, found.second_factor?, found.tokens?}.should eq({false, true, true, false})
      {found.deploy, found.ci, found.languages}.should eq({"systemd", "none", %w[en de]})
      found.dependency.path.should eq(app.dependency.path)
      Punch::CLI::New::Template.render(found).map(&.path).should eq(Punch::CLI::New::Template.render(app).map(&.path))
    end
  end

  it "names what is missing in a directory that is not an app" do
    root = File.tempname("generate-spec")
    Dir.mkdir_p(root)
    Punch::CLI::New::Detect.app(root).as(String).should contain("shard.yml is missing")
    File.write(File.join(root, "shard.yml"), "name: ../../escape\n")
    Punch::CLI::New::Detect.app(root).as(String).should contain("an app name is lowercase")
  ensure
    FileUtils.rm_rf(root) if root
  end
end

describe "Punch::CLI::Generate.confined!" do
  it "refuses a path that leaves the app or passes a symbolic link" do
    root = File.tempname("generate-spec")
    Dir.mkdir_p(File.join(root, "app"))
    File.symlink("/tmp", File.join(root, "app", "linked"))
    Punch::CLI::Generate.confined!(root, "app/new.cr")
    expect_raises(ArgumentError, "outside the app") { Punch::CLI::Generate.confined!(root, "../x.cr") }
    expect_raises(ArgumentError, "outside the app") { Punch::CLI::Generate.confined!(root, "/etc/x") }
    expect_raises(ArgumentError, "symbolic link") { Punch::CLI::Generate.confined!(root, "app/linked/x.cr") }
  ensure
    FileUtils.rm_rf(root) if root
  end
end

describe Punch::CLI::Generate do
  it "takes a namespace as directories or as a module, and refuses the names of file kinds" do
    Generate.segments("billing/plans").should eq(%w[billing plans])
    Generate.segments("Billing::PricePlans").should eq(%w[billing price_plans])
    Generate.segments("billing/operations").as(String).should contain("kind")
    Generate.segments("billing/types").as(String).should contain("kind")
    Generate.segments("Billing/plans").as(String).should contain("lowercase")
  end

  it "writes a namespace's outline, and a parent's when it has none, with the placeholder the lint reports" do
    with_app do |root|
      result = plan(Generate.namespace(root, "billing/payments/refunds"))
      result.writes.map(&.path).should eq(%w[app/billing.cr app/billing/payments.cr app/billing/payments/refunds.cr])
      written(result, "app/billing/payments/refunds.cr").should start_with(Generate::PLACEHOLDER)
      written(result, "app/billing/payments/refunds.cr").should contain("module Billing::Payments::Refunds\nend\n")

      plan(Generate.namespace(root, "accounts/invitations")).writes.map(&.path).should eq(%w[app/accounts/invitations.cr])
      failure(Generate.namespace(root, "accounts/sessions")).code.should eq("exists")
    end
  end

  it "writes an entity with a migration for its table when the schema has none, and holds the steps" do
    with_app do |root|
      result = plan(Generate.entity(root, "billing/plans", nil))
      migration = result.writes.find!(&.path.ends_with?("_create_plans.sql"))
      migration.content.should contain("CREATE TABLE plans (\n  id INTEGER PRIMARY KEY AUTOINCREMENT\n) STRICT;")
      written(result, "app/billing/plans/columns.cr").should contain(%(Punch.table "plans", Billing::Plans,\n  id: Billing::Plans::ID\n))
      written(result, "app/billing/plans/types.cr").should contain("struct ID < Punch::TypedID")
      result.writes.map(&.path).should contain("app/billing/plans/queries.sql")
      result.held?.should be_true
      result.todo.first.should contain("outline")
    end
  end

  it "maps an existing table's ID, the IDs it references, and its times, and lists the rest" do
    with_app do |root|
      schema(root, <<-SQL)
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL, locale TEXT) STRICT;
        CREATE TABLE price_plans (
          id INTEGER PRIMARY KEY,
          owner_id INTEGER NOT NULL REFERENCES users (id),
          name TEXT NOT NULL,
          created_at TEXT NOT NULL,
          archived_at TEXT
        ) STRICT;
        CREATE TABLE loose (id INTEGER PRIMARY KEY, note TEXT);
        SQL
      result = plan(Generate.entity(root, "billing/plans", "price_plans"))
      result.held?.should be_false
      result.writes.none?(&.path.starts_with?("db/")).should be_true
      columns = written(result, "app/billing/plans/columns.cr")
      columns.should contain(%(Punch.table "price_plans", Billing::Plans,\n  id: Billing::Plans::ID,\n  owner_id: Accounts::Users::ID,\n  created_at: Time,\n  archived_at: Time\n))
      columns.should contain("#   name: String\n")

      failure(Generate.entity(root, "accounts/people", "users")).code.should eq("mapped")
      failure(Generate.entity(root, "billing/loose", nil)).code.should eq("not_strict")
      failure(Generate.entity(root, "billing/plans", "punch_sessions")).code.should eq("invalid_table")
    end
  end

  it "adds a part: new files, untouched ones replaced, edited ones in a patch, the migration at the current time" do
    with_app do |root|
      layout = File.join(root, "app/components/layout.cr")
      File.write(layout, "# Our layout.\n" + File.read(layout))
      result = plan(Generate.part(root, "organizations"))
      paths = result.writes.map(&.path)
      paths.should contain("app/accounts/organizations/operations/switch.cr")
      paths.should contain("spec/accounts/organizations/switch_spec.cr")
      migration = paths.find!(&.ends_with?("_create_organizations.sql"))
      migration.should_not eq("db/migrations/20261023000500_create_organizations.sql")
      result.migration?.should be_true
      result.replaces.map(&.path).should contain("app/actor.cr")
      written(result, "app/actor.cr").should contain("organization")
      result.edited.should eq(%w[app/components/layout.cr])
      result.patch.should contain("--- a/app/components/layout.cr\n+++ b/app/components/layout.cr\n")
      result.patch.should contain("+                chrome.a t.organizations")

      Generate.write(root, result)
      failure(Generate.part(root, "organizations")).code.should eq("exists")
    end
  end

  it "refuses a part whose files the app has already, and a part it does not know" do
    with_app(App.new("tally", "Tally", tokens: false)) do |root|
      Dir.mkdir_p(File.join(root, "spec/accounts/tokens"))
      File.write(File.join(root, "spec/accounts/tokens/create_spec.cr"), "# mine\n")
      failure(Generate.part(root, "tokens")).message.should contain("spec/accounts/tokens/create_spec.cr")
      failure(Generate.part(root, "billing")).code.should eq("unknown_part")
    end
  end
end

describe "AGENTS.md of a new app" do
  it "names the accounts parts the app can still add, and none when it has every one" do
    agents = Punch::CLI::New::Template.render(App.new("tally", "Tally")).find!(&.path.==("AGENTS.md")).content
    agents.should contain("## Adding to the accounts slice")
    agents.should contain("`magic_links`, sign-in by a link in an email; `organizations`")
    agents.should_not contain("`tokens`, API tokens")
    every = App.new("tally", "Tally", magic_links: true, organizations: true)
    Punch::CLI::New::Template.render(every).find!(&.path.==("AGENTS.md")).content.should_not contain("Adding to the accounts slice")
  end
end

describe Punch::CLI::Commands::Generate do
  it "refuses what it does not know before looking at any file" do
    command = Punch::CLI::Commands::Generate.new(Punch::CLI::TOOL_COMMANDS)
    command.run(%w[operation billing/plans/create]).as(Punch::CLI::Failure).code.should eq("unknown_generator")
    command.run(%w[namespace billing/plans --table plans]).as(Punch::CLI::Failure).code.should eq("unexpected_argument")
    command.run(%w[entity]).as(Punch::CLI::Failure).code.should eq("missing_argument")
  end
end
