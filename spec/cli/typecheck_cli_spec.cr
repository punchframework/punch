require "../spec_helper"
require "../support/app_fixture"
require "../../src/punch/cli/tool"

private def typecheck(args : Array(String) = [] of String) : {Int32, JSON::Any}
  stdout = IO::Memory.new
  code = Punch::CLI.run(["typecheck"] + args + ["--json"], stdout, IO::Memory.new, Punch::CLI::TOOL_COMMANDS)
  {code, JSON.parse(stdout.to_s)}
end

describe Punch::CLI::Commands::Typecheck do
  it "type-checks the app without leaving a binary, and reports the compiler's error when it fails" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      code, document = typecheck
      code.should eq(0)
      document["main"].should eq("src/tiny.cr")
      Dir.exists?("bin").should be_false
      Dir.exists?("tmp").should be_false

      File.write("src/tiny.cr", File.read("src/tiny.cr").sub("MESSAGE = \"one\"", "MESSAGE = nothing_here"))
      code, document = typecheck
      code.should eq(1)
      document["error"]["code"].should eq("typecheck_failed")
      document["error"]["message"].as_s.should contain("undefined local variable or method 'nothing_here'")
    end
  end

  it "takes no arguments" do
    typecheck(["--fast"])[0].should eq(2)
  end
end
