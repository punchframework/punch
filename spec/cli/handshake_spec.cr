require "../spec_helper"
require "../../src/punch/cli/tool"

# An app directory with a `lib/punch` of *version*, a format declaration when
# *format* is given, and a built tool when *tool* is.
private def with_app(version : String, format : Int32? = nil, tool : Bool = false, repository : String? = nil, & : String ->) : Nil
  root = File.tempname("punch-handshake")
  Dir.mkdir_p("#{root}/lib/punch/src/punch/cli/tool")
  File.write("#{root}/shard.lock", "version: 2.0\nshards:\n  punch:\n    git: https://github.com/#{repository}.git\n    version: #{version}\n") if repository
  File.write("#{root}/lib/punch/shard.yml", "name: punch\nversion: #{version}\n")
  File.write("#{root}/lib/punch/src/punch/cli/tool/handshake.cr", "module Punch::CLI\n  GENERATOR_FORMAT = #{format}\nend\n") if format
  if tool
    Dir.mkdir_p("#{root}/lib/punch/bin")
    File.write("#{root}/lib/punch/bin/punch", "#!/bin/sh\n")
    File.chmod("#{root}/lib/punch/bin/punch", 0o755)
  end
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private alias Handshake = Punch::CLI::Handshake

describe Punch::CLI::Handshake do
  it "proceeds where there is no lib/punch, as in the Punch repository itself" do
    Handshake.decide(File.expand_path("#{__DIR__}/../.."), "/somewhere/punch").should be_a(Handshake::Proceed)
  end

  it "proceeds when the versions and the generator format match" do
    with_app(Punch::VERSION) { |root| Handshake.decide(root, "/x/punch").should be_a(Handshake::Proceed) }
    with_app(Punch::VERSION, Punch::CLI::GENERATOR_FORMAT) { |root| Handshake.decide(root, "/x/punch").should be_a(Handshake::Proceed) }
  end

  it "re-execs lib/punch/bin/punch when the versions differ" do
    with_app("9.9.9", tool: true) do |root|
      decision = Handshake.decide(root, "/x/punch").as(Handshake::Reexec)
      decision.path.should eq("#{root}/lib/punch/bin/punch")
    end
  end

  it "re-execs when only the generator format differs" do
    with_app(Punch::VERSION, Punch::CLI::GENERATOR_FORMAT + 1, tool: true) { |root| Handshake.decide(root, "/x/punch").should be_a(Handshake::Reexec) }
  end

  it "does not re-exec itself, nor again in the process it started" do
    with_app("9.9.9", tool: true) do |root|
      Handshake.decide(root, "#{root}/lib/punch/bin/punch").should be_a(Handshake::Refuse)
      Handshake.decide(root, "/x/punch", guarded: true).should be_a(Handshake::Proceed)
    end
  end

  it "refuses with the command that builds the matching tool when there is none" do
    with_app("9.9.9") do |root|
      failure = Handshake.decide(root, "/x/punch").as(Handshake::Refuse).failure
      failure.code.should eq("tool_mismatch")
      failure.message.should contain("Punch #{Punch::VERSION}")
      failure.message.should contain("9.9.9")
      failure.message.should contain("crystal build lib/punch/src/cli/main.cr -o lib/punch/bin/punch")
    end
  end

  it "re-execs the release's tool that tool:install put in the cache" do
    with_app("9.9.9", repository: "owner/punch") do |root|
      tools = "#{root}/tools"
      Dir.mkdir_p("#{tools}/owner/punch/9.9.9")
      File.write("#{tools}/owner/punch/9.9.9/punch", "#!/bin/sh\n")
      File.chmod("#{tools}/owner/punch/9.9.9/punch", 0o755)
      Handshake.decide(root, "/x/punch", tools: tools).as(Handshake::Reexec).path.should eq("#{tools}/owner/punch/9.9.9/punch")
    end
  end

  it "prefers lib/punch/bin/punch to an installed release's tool" do
    with_app("9.9.9", tool: true, repository: "owner/punch") do |root|
      Dir.mkdir_p("#{root}/tools/owner/punch/9.9.9")
      File.write("#{root}/tools/owner/punch/9.9.9/punch", "#!/bin/sh\n")
      File.chmod("#{root}/tools/owner/punch/9.9.9/punch", 0o755)
      Handshake.decide(root, "/x/punch", tools: "#{root}/tools").as(Handshake::Reexec).path.should eq("#{root}/lib/punch/bin/punch")
    end
  end

  it "names tool:install when the app has Punch from GitHub and no tool is installed" do
    with_app("9.9.9", repository: "owner/punch") do |root|
      failure = Handshake.decide(root, "/x/punch", tools: "#{root}/tools").as(Handshake::Refuse).failure
      failure.message.should contain("punch tool:install 9.9.9")
      failure.message.should contain("crystal build lib/punch/src/cli/main.cr -o lib/punch/bin/punch")
    end
  end

  it "lets help and version run whatever the tool is" do
    with_app("9.9.9") do |root|
      Handshake.enforce(["version", "--json"], root).should be_nil
      Handshake.enforce(["tool:install", "9.9.9"], root).should be_nil
      Handshake.enforce([] of String, root).should be_nil
      Handshake.enforce(["routes"], root).try(&.code).should eq("tool_mismatch")
    end
  end
end
