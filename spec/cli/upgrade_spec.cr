require "../spec_helper"
require "../../src/punch/cli/tool"

private alias Upgrade = Punch::CLI::Upgrade
private alias Status = Punch::CLI::Upgrade::Status

private def directory(&)
  root = File.tempname("upgrade-spec")
  Dir.mkdir_p(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def put(root : String, path : String, content : String) : Nil
  File.join(root, path).tap do |file|
    Dir.mkdir_p(File.dirname(file))
    File.write(file, content)
  end
end

private def git(root : String, *args : String) : Nil
  Process.run("git", ["-C", root, "-c", "user.name=spec", "-c", "user.email=spec@example.org"] + args.to_a,
    output: Process::Redirect::Close, error: Process::Redirect::Inherit).success?.should be_true
end

private def lock(version : String) : String
  "version: 2.0\nshards:\n  punch:\n    path: /src/punch\n    version: #{version}\n"
end

describe Punch::CLI::Upgrade do
  it "finds the Punch the app had before, in shard.lock's history" do
    directory do |root|
      git(root, "init", "--quiet")
      put(root, "shard.lock", lock("0.1.0"))
      git(root, "add", "shard.lock")
      git(root, "commit", "--quiet", "-m", "0.1.0")
      put(root, "shard.lock", lock("0.2.0"))
      git(root, "commit", "--quiet", "-am", "0.2.0")
      Upgrade.previous_version(root, "0.2.0").should eq("0.1.0")
      # Not committed yet: HEAD has the previous one.
      put(root, "shard.lock", lock("0.3.0"))
      Upgrade.previous_version(root, "0.3.0").should eq("0.2.0")
      Upgrade.previous_version(root, "0.1.0").should eq("0.2.0")
    end
  end

  it "asks for --from when every commit has the same Punch, as a path dependency does" do
    directory do |root|
      git(root, "init", "--quiet")
      put(root, "shard.lock", lock("0.1.0"))
      git(root, "add", "shard.lock")
      git(root, "commit", "--quiet", "-m", "first")
      Upgrade.previous_version(root, "0.1.0").as(Punch::CLI::Failure).message.should contain("--from")
    end
    directory do |root|
      Upgrade.previous_version(root, "0.1.0").as(Punch::CLI::Failure).code.should eq("no_history")
    end
  end

  it "tells each changed file's status, and keeps applied migrations out of the patch" do
    directory do |root|
      git(root, "init", "--quiet")
      put(root, "a.cr", "one\ntwo\n")
      put(root, "b.cr", "one\ntwo\nthree\nfour\nfive\nsix\nseven\n# ours\n")
      put(root, "c.cr", "mine\n")
      put(root, "gone.cr", "old\n")
      put(root, "db/migrations/20261023000100_add_punch_auth.sql", "CREATE TABLE a (x);\n")
      before = {"a.cr" => "one\ntwo\n", "b.cr" => "one\ntwo\nthree\nfour\nfive\nsix\nseven\n", "c.cr" => "theirs\n",
                "gone.cr" => "old\n", "same.cr" => "same\n", "deleted.cr" => "x\n",
                "db/migrations/20261023000100_add_punch_auth.sql" => "CREATE TABLE a (x);\n"}
      after = {"a.cr" => "one\n2\n", "b.cr" => "1\ntwo\nthree\nfour\nfive\nsix\nseven\n", "c.cr" => "changed\n",
               "same.cr" => "same\n", "deleted.cr" => "y\n", "new.cr" => "new\n",
               "db/migrations/20261023000100_add_punch_auth.sql" => "CREATE TABLE a (x, y);\n",
               "db/migrations/20261101000000_add_punch_things.sql" => "CREATE TABLE t (x);\n"}
      changes = Upgrade.compare(root, before, after).to_h { |change| {change.path.sub(/\d{14}_add_punch_things/, "NOW_add_punch_things"), change} }
      changes.transform_values(&.status).should eq({
        "a.cr"                                            => Status::Untouched,
        "b.cr"                                            => Status::Applies,
        "c.cr"                                            => Status::Conflicts,
        "db/migrations/20261023000100_add_punch_auth.sql" => Status::Migration,
        "db/migrations/NOW_add_punch_things.sql"          => Status::New,
        "deleted.cr"                                      => Status::Missing,
        "gone.cr"                                         => Status::Removed,
        "new.cr"                                          => Status::New,
      })
      changes["a.cr"].patch.should contain("--- a/a.cr\n+++ b/a.cr\n")
      changes["deleted.cr"].status.patched?.should be_false
      changes["new.cr"].patch.should contain("--- /dev/null\n+++ b/new.cr\n")
      changes["gone.cr"].patch.should contain("--- a/gone.cr\n+++ /dev/null\n")
      changes["db/migrations/NOW_add_punch_things.sql"].path.should_not contain("20261101000000")

      changes.values.select(&.status.patched?).map(&.path).sort!.first(3).should eq(%w[a.cr b.cr c.cr])
      changes["a.cr"].patch.should match(/\Adiff --git a\/a.cr b\/a.cr\nindex [0-9a-f]{40}\.\.[0-9a-f]{40} 100644\n/)
      git(root, "add", "--all")
      git(root, "commit", "--quiet", "-m", "app")
      patch = changes.values.select(&.status.patched?).join(&.patch)
      put(root, "all.patch", patch)
      Process.run("git", ["-C", root, "apply", "--3way", "all.patch"], output: Process::Redirect::Close, error: Process::Redirect::Close)
      File.read(File.join(root, "a.cr")).should eq("one\n2\n")
      File.read(File.join(root, "b.cr")).should eq("1\ntwo\nthree\nfour\nfive\nsix\nseven\n# ours\n")
      File.read(File.join(root, "c.cr")).should contain("<<<<<<<")
      File.exists?(File.join(root, "new.cr")).should be_true
      File.exists?(File.join(root, "gone.cr")).should be_false
    end
  end
end

# A git repository with a Punch-like tree under *prefix*, tagged v0.1.0.
private def punch_repository(root : String, prefix : String) : String
  repository = File.join(root, "punch-repo")
  Dir.mkdir_p(repository)
  git(repository, "init", "--quiet")
  put(repository, File.join(prefix, "src/cli/main.cr"), "# 0.1.0\n")
  git(repository, "add", "--all")
  git(repository, "commit", "--quiet", "-m", "0.1.0")
  git(repository, "tag", "v0.1.0")
  put(repository, File.join(prefix, "src/cli/main.cr"), "# later\n")
  git(repository, "commit", "--quiet", "-am", "later")
  repository
end

describe "Punch::CLI::Upgrade.source" do
  it "exports a tag of a path dependency's checkout, also from a directory of a larger repository" do
    directory do |root|
      ENV["XDG_CACHE_HOME"] = File.join(root, "cache")
      checkout = File.join(punch_repository(root, "punch"), "punch")
      put(root, "app/shard.lock", "version: 2.0\nshards:\n  punch:\n    path: #{checkout}\n    version: 0.2.0\n")
      source, label, cached = Upgrade.source(File.join(root, "app"), nil, "0.1.0").as(Tuple)
      {label, cached}.should eq({"0.1.0", true})
      File.read(File.join(source, "src/cli/main.cr")).should eq("# 0.1.0\n")
      Upgrade.source(File.join(root, "app"), "HEAD", nil).as(Tuple)[0].should_not eq(source)
    end
  end

  it "clones a git dependency's tag" do
    directory do |root|
      ENV["XDG_CACHE_HOME"] = File.join(root, "cache")
      repository = punch_repository(root, "")
      put(root, "app/shard.lock", "version: 2.0\nshards:\n  punch:\n    git: file://#{repository}\n    version: 0.2.0\n")
      source = Upgrade.source(File.join(root, "app"), nil, "0.1.0").as(Tuple)[0]
      File.read(File.join(source, "src/cli/main.cr")).should eq("# 0.1.0\n")
      Upgrade.source(File.join(root, "app"), "0.9.0", nil).as(Punch::CLI::Failure).code.should eq("no_source")
      # A version text decides nothing about paths, and is no option.
      ["../../outside", "--upload-pack=x", "a/../b"].each do |wanted|
        Upgrade.source(File.join(root, "app"), wanted, nil).as(Punch::CLI::Failure).code.should eq("invalid_ref")
      end
    end
  end
end

describe Punch::CLI::Commands::TemplateRender do
  it "refuses a directory that is not empty, before reading the app" do
    directory do |root|
      put(root, "x", "x")
      Punch::CLI::Commands::TemplateRender.new(Punch::CLI::TOOL_COMMANDS).run([root]).as(Punch::CLI::Failure).code.should eq("directory_not_empty")
    end
  end
end
