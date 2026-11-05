require "../spec_helper"
require "../../src/punch/cli/tool"

private alias Released = Punch::CLI::Released

# A release of *version* on disk, as GitHub serves one: the archive of a
# stand-in tool that prints *reports*, and SHA256SUMS (with *sum* in place
# of the archive's when given). Yields the base URL and a cache directory.
private def with_release(version : String, reports : String = "punch #{version} (stand-in)", sum : String? = nil, & : String, String ->) : Nil
  root = File.tempname("punch-released")
  name = "punch-#{version}-test-arch"
  release = "#{root}/owner/punch/releases/download/v#{version}"
  Dir.mkdir_p("#{root}/#{name}")
  Dir.mkdir_p(release)
  File.write("#{root}/#{name}/punch", "#!/bin/sh\necho '#{reports}'\n")
  File.chmod("#{root}/#{name}/punch", 0o755)
  Process.run("tar", ["-czf", "#{release}/#{name}.tar.gz", "-C", root, name]).success?.should be_true
  actual = Digest::SHA256.new.file("#{release}/#{name}.tar.gz").hexfinal
  File.write("#{release}/SHA256SUMS", "#{sum || actual}  #{name}.tar.gz\n")
  begin
    yield "file://#{root}", "#{root}/cache"
  ensure
    FileUtils.rm_rf(root)
  end
end

describe Punch::CLI::Released do
  it "installs a release's tool after checking its checksum and version" do
    with_release("9.9.9") do |base, cache|
      path, present = Released.install("owner/punch", "9.9.9", cache: cache, base: base, platform: "test-arch").as(Tuple)
      path.should eq("#{cache}/owner/punch/9.9.9/punch")
      present.should be_false
      File::Info.executable?(path).should be_true
      Released.installed("owner/punch", "9.9.9", cache).should eq(path)
      Released.install("owner/punch", "9.9.9", cache: cache, base: base, platform: "test-arch").as(Tuple)[1].should be_true
    end
  end

  it "installs nothing when the checksum differs" do
    with_release("9.9.9", sum: "0" * 64) do |base, cache|
      failure = Released.install("owner/punch", "9.9.9", cache: cache, base: base, platform: "test-arch").as(Punch::CLI::Failure)
      failure.code.should eq("checksum_mismatch")
      Released.installed("owner/punch", "9.9.9", cache).should be_nil
      Dir.children(cache).should be_empty # no download left behind
    end
  end

  it "installs nothing that reports another version" do
    with_release("9.9.9", reports: "punch 1.0.0 (stand-in)") do |base, cache|
      Released.install("owner/punch", "9.9.9", cache: cache, base: base, platform: "test-arch").as(Punch::CLI::Failure).code.should eq("download_failed")
      Released.installed("owner/punch", "9.9.9", cache).should be_nil
    end
  end

  it "refuses versions, repositories, and URLs that could name another place" do
    Released.install("owner/punch", "../9", cache: "/nowhere", base: "file:///nowhere", platform: "x").as(Punch::CLI::Failure).code.should eq("invalid_version")
    Released.install("../..", "9.9.9", cache: "/nowhere", base: "file:///nowhere", platform: "x").as(Punch::CLI::Failure).code.should eq("invalid_repository")
    Released.install("owner/../x", "9.9.9", cache: "/nowhere", base: "file:///nowhere", platform: "x").as(Punch::CLI::Failure).code.should eq("invalid_repository")
    Released.install("owner/punch", "9.9.9", cache: "/nowhere", base: "http://example.test", platform: "x").as(Punch::CLI::Failure).code.should eq("invalid_releases_url")
  end

  it "says so where releases carry no tool for the platform" do
    Released.install("owner/punch", "9.9.9", cache: "/nowhere", base: "file:///nowhere", platform: nil).as(Punch::CLI::Failure).code.should eq("no_release_tool")
  end

  it "reads the GitHub repository from the app's shard.lock" do
    root = File.tempname("punch-released-lock")
    Dir.mkdir_p(root)
    begin
      Released.repository(root).should be_nil
      File.write("#{root}/shard.lock", "version: 2.0\nshards:\n  punch:\n    git: https://github.com/owner/punch.git\n    version: 0.1.0\n")
      Released.repository(root).should eq("owner/punch")
      File.write("#{root}/shard.lock", "version: 2.0\nshards:\n  punch:\n    path: ../punch\n    version: 0.1.0\n")
      Released.repository(root).should be_nil
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
