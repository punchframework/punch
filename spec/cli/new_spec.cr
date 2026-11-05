require "../spec_helper"
require "../../src/punch/cli/tool"

private alias App = Punch::CLI::New::App
private alias Template = Punch::CLI::New::Template

private def paths(app : App) : Array(String)
  Template.render(app).map(&.path)
end

private def content(app : App, path : String) : String
  Template.render(app).find!(&.path.==(path)).content
end

private def run(*args : String) : Punch::CLI::Report | Punch::CLI::Failure
  Punch::CLI::Commands::New.new(Punch::CLI::TOOL_COMMANDS).run(args.to_a)
end

describe Punch::CLI::New::Template do
  it "renders every file for every combination of parts, leaving no template syntax" do
    [App.new("tally", "Tally"),
     App.new("allon", "Allon", magic_links: true, organizations: true, languages: %w[en de], deploy: "systemd"),
     App.new("alloff", "Alloff", second_factor: false, tokens: false, deploy: "none", ci: "none")].each do |app|
      Template.render(app).each do |file|
        file.content.should_not contain("<%")
        file.path.should_not contain("__name__")
      end
    end
  end

  it "writes the parts that were asked for, and only those" do
    default = paths(App.new("tally", "Tally"))
    default.should contain("app/accounts/second_factor.cr")
    default.should contain("app/accounts/tokens/pages/index_page.cr")
    default.should_not contain("app/accounts/magic_links.cr")
    default.should_not contain("app/accounts/organizations.cr")
    default.should_not contain("spec/journeys/magic_link_spec.cr")
    default.should_not contain("db/migrations/20261023000500_create_organizations.sql")
    default.should contain("config/deploy.yml")
    default.should_not contain("deploy/deploy.sh")
    default.should contain(".github/workflows/check.yml")
    default.should_not contain("config/locales/accounts/de.yml")
    default.should contain("src/tally.cr")

    off = paths(App.new("alloff", "Alloff", second_factor: false, tokens: false, deploy: "none", ci: "none"))
    off.should_not contain("app/accounts/second_factor.cr")
    off.should_not contain("spec/accounts/tokens/create_spec.cr")
    off.should_not contain("Dockerfile")
    off.should_not contain(".github/workflows/check.yml")

    on = paths(App.new("allon", "Allon", magic_links: true, organizations: true, languages: %w[en de], deploy: "systemd"))
    on.should contain("app/accounts/organizations/members/operations/create.cr")
    on.should contain("deploy/allon@.service")
    on.should contain("config/locales/accounts/de.yml")
    on.should_not contain("config/deploy.yml")
  end

  it "leaves a part's code out of the files every app has" do
    app = App.new("alloff", "Alloff", second_factor: false, tokens: false)
    content(app, "app/accounts/sessions/operations/create.cr").should_not contain("SecondFactor")
    content(app, "app/accounts/sessions/pages/index_page.cr").should_not contain("Tokens::")
    content(app, "app/actor.cr").should_not contain("Organizations")
    content(app, "app/accounts/roles.cr").should contain("struct Operator")
    content(app, "app/accounts/roles.cr").should_not contain("Administrator")
  end

  it "names the app after its directory, Punch's tables from Punch's own SQL" do
    app = App.new("time-sheets", App.module_for("time-sheets"))
    app.module_name.should eq("TimeSheets")
    app.title.should eq("Time Sheets")
    app.token_prefix.should eq("tim")
    content(app, "src/main.cr").should contain(%(require "./time-sheets"))
    content(app, "app/setup.cr").should contain(%(token_prefix: "tim"))
    content(app, "app/setup.cr").should contain("Punch.translations TimeSheets::Translations")
    content(app, "db/migrations/20261023000100_add_punch_auth.sql").should eq(Punch::Auth::Schema.sql("users"))
    content(app, ".tool-versions").should eq("crystal #{Punch::CLI::New::CRYSTAL}\n")
  end

  it "pins the Crystal archives the devcontainer downloads, and gets the tool with the app's script" do
    app = App.new("tally", "Tally")
    dockerfile = content(app, ".devcontainer/Dockerfile")
    Punch::CLI::New::CRYSTAL_SHA256.values.each { |sha256| dockerfile.should contain("sha256=#{sha256}") }
    dockerfile.should contain("sha256sum --check --strict")
    paths(app).should contain("scripts/punch-tool.sh")
    content(app, ".devcontainer/devcontainer.json").should contain("shards install && scripts/punch-tool.sh")
    content(app, ".github/workflows/check.yml").should contain("run: scripts/punch-tool.sh")
  end

  it "depends on Punch by path while Punch has no repository" do
    app = App.new("tally", "Tally", dependency: Punch::CLI::New::Dependency.new("/src/punch", nil, "0.1.0"))
    content(app, "shard.yml").should contain("  punch:\n    path: /src/punch\n")
    content(app, "Dockerfile").should contain("--build-context punch=/src/punch")
    git = App.new("tally", "Tally", dependency: Punch::CLI::New::Dependency.new(nil, "punch/punch", "0.1.0"))
    content(git, "shard.yml").should contain("  punch:\n    github: punch/punch\n    version: \"~> 0.1.0\"\n")
    content(git, "Dockerfile").should_not contain("build-context")
  end
end

describe "punch new" do
  it "refuses a directory that is not empty, and names it can't use" do
    parent = File.tempname("punch-new")
    directory = File.join(parent, "tally")
    Dir.mkdir_p(directory)
    File.write(File.join(directory, "keep"), "")
    begin
      run(directory).as(Punch::CLI::Failure).code.should eq("directory_not_empty")
    ensure
      FileUtils.rm_rf(parent)
    end
    run("Tally").as(Punch::CLI::Failure).code.should eq("invalid_name")
    run("tally", "--module", "tally").as(Punch::CLI::Failure).code.should eq("invalid_module")
    run("accounts").as(Punch::CLI::Failure).code.should eq("invalid_module")
    run("tally", "--deploy", "heroku").as(Punch::CLI::Failure).message.should contain("kamal, systemd, none")
    run("tally", "--languages", "en,fr").as(Punch::CLI::Failure).code.should eq("invalid_choice")
    run("tally", "--environments", "test,production").as(Punch::CLI::Failure).code.should eq("invalid_environment")
    run("tally", "--colour").as(Punch::CLI::Failure).code.should eq("unexpected_argument")
    run("tally", "extra").as(Punch::CLI::Failure).code.should eq("missing_argument")
  end
end
