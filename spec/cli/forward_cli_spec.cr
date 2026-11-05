require "../spec_helper"
require "../support/app_fixture"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args : String, commands = Punch::CLI::TOOL_COMMANDS, program : String? = nil) : Run
  invoke(args.to_a, commands, program)
end

private def invoke(args : Array(String), commands, program : String?) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  fallback = commands == Punch::CLI::TOOL_COMMANDS ? Punch::CLI::Forward::FALLBACK : nil
  code = Punch::CLI.run(args, stdout, stderr, commands, fallback, program)
  Run.new(code, stdout.to_s, stderr.to_s)
end

describe "one entry point for the tool's and the app's commands" do
  it "forwards a command of the app's binary, with its output and exit code" do
    AppFixture.copy("spec/openapi/fixture") do
      File.write("shard.yml", File.read("shard.yml") + "\ndependencies:\n  punch:\n    path: lib/punch\n")
      types = punch("jobs:types", "--json")
      types.code.should eq(0)
      JSON.parse(types.stdout)["types"].as_a.should be_a(Array(JSON::Any))
      types.stderr.should be_empty

      # The binary's usage error comes through as its own, exit code 2.
      missing = punch("tokens:create", "--json")
      missing.code.should eq(2)
      JSON.parse(missing.stdout)["error"]["code"].should eq("missing_argument")
    end
  end

  it "answers a command nobody has with the usage error, without building" do
    AppFixture.copy("spec/openapi/fixture") do
      run = punch("nope", "--json")
      run.code.should eq(2)
      JSON.parse(run.stdout)["error"]["code"].should eq("unknown_command")
      File.exists?(Punch::CLI::Forward::BINARY).should be_false
    end
  end

  it "says which app command it is when there is no app here" do
    directory = File.tempname("punch-empty")
    Dir.mkdir(directory)
    begin
      Dir.cd(directory) do
        run = punch("jobs:versions", "--json")
        run.code.should eq(1)
        JSON.parse(run.stdout)["error"]["code"].should eq("no_app")
        JSON.parse(run.stdout)["error"]["message"].as_s.should contain("application's binary")
      end
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "suggests the command a typo means, from either binary" do
    run = punch("rotes", "--json")
    run.code.should eq(2)
    error = JSON.parse(run.stdout)["error"]
    error["code"].should eq("unknown_command")
    error["message"].as_s.should contain("Did you mean 'routes'")
    error["details"]["did_you_mean"].as_a.map(&.as_s).first.should eq("routes")
    punch("jobs:verions").stdout.should be_empty
    punch("jobs:verions").stderr.should contain("'jobs:versions'")
    punch("zzzzzz").stderr.should_not contain("Did you mean")
  end

  it "names the binary in its usage and messages" do
    invoke(Array(String).new, Punch::CLI::APP_COMMANDS, "shop").stdout.should start_with("Usage: shop <command>")
    invoke(["nope"], Punch::CLI::APP_COMMANDS, "shop").stderr.should start_with("shop: Unknown command")
    invoke(Array(String).new, Punch::CLI::TOOL_COMMANDS, nil).stdout.should start_with("Usage: punch <command>")
  end
end
