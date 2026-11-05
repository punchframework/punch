require "../spec_helper"
require "http/client"
require "../support/app_fixture"
require "../../src/punch/cli/tool"

private def body(port : Int32) : String?
  HTTP::Client.get("http://127.0.0.1:#{port}/").body
rescue Socket::ConnectError | IO::Error
  nil
end

# Waits until the app answers *expected*; builds take seconds.
private def wait_for(port : Int32, expected : String?, log : AppFixture::Log) : Nil
  Punch::Spec.eventually(90.seconds) { body(port).should eq(expected) }
rescue ex : Spec::AssertionFailed
  fail "#{ex.message}\nlog:\n#{log}"
end

describe Punch::CLI::DevLoop do
  it "builds and serves the app, restarts it on a change, keeps it through a failed build, and stops it" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do |directory|
      port = AppFixture.free_port
      settings = Punch::AppConfig.new(storage: "#{directory}/storage", port: port)
      project = Punch::CLI::Project.load.as(Punch::CLI::Project)
      log = AppFixture::Log.new
      dev = Punch::CLI::DevLoop.new(project, settings, log, poll: 50.milliseconds, env: {"PUNCH_PORT" => port.to_s})
      done = Channel(Nil).new
      spawn { dev.run; done.send(nil) }

      wait_for(port, "one", log)
      log.to_s.should contain("punch dev: started in")

      source = File.read("src/tiny.cr")
      File.write("src/tiny.cr", source.sub(%("one"), %("two")))
      wait_for(port, "two", log)
      log.to_s.should contain("punch dev: changed: src/tiny.cr")

      File.write("src/tiny.cr", source.sub(%(MESSAGE = "one"), "MESSAGE = (\"three\""))
      Punch::Spec.eventually(90.seconds) { log.to_s.should contain("build failed") }
      log.to_s.should contain("the running app is unchanged")
      body(port).should eq("two")

      dev.stop
      done.receive
      dev.app_running?.should be_false
      body(port).should be_nil
      dev.rounds.should eq(3)
    end
  end

  it "regenerates the translations in each round, beside the queries" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do |directory|
      Dir.mkdir_p("config/locales")
      Dir.mkdir_p("app")
      File.write("config/locales/en.yml", "en:\n  greeting: \"Hello\"\n")
      File.write("app/setup.cr", "Punch.translations Tiny::Translations, default: \"en\"\n")
      port = AppFixture.free_port
      settings = Punch::AppConfig.new(storage: "#{directory}/storage", port: port)
      project = Punch::CLI::Project.load.as(Punch::CLI::Project)
      log = AppFixture::Log.new
      dev = Punch::CLI::DevLoop.new(project, settings, log, poll: 50.milliseconds, env: {"PUNCH_PORT" => port.to_s})
      done = Channel(Nil).new
      spawn { dev.run; done.send(nil) }
      begin
        wait_for(port, "one", log)
        File.read("app/translations.gen.cr").should contain("greeting")
        log.to_s.should contain("punch dev: i18n:generate: written")
        File.write("config/locales/en.yml", "en:\n  greeting: \"Hello\"\n  farewell: \"Bye\"\n")
        Punch::Spec.eventually(90.seconds) { File.read("app/translations.gen.cr").should contain("farewell") }
      ensure
        dev.stop
        done.receive
      end
    end
  end

  it "builds again when a file is saved during a build, and logs each round" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do |directory|
      port = AppFixture.free_port
      settings = Punch::AppConfig.new(storage: "#{directory}/storage", port: port)
      project = Punch::CLI::Project.load.as(Punch::CLI::Project)
      log = AppFixture::Log.new
      dev = Punch::CLI::DevLoop.new(project, settings, log, poll: 50.milliseconds, env: {"PUNCH_PORT" => port.to_s})
      done = Channel(Nil).new
      spawn { dev.run; done.send(nil) }
      begin
        wait_for(port, "one", log)
        source = File.read("src/tiny.cr")
        File.write("src/tiny.cr", source.sub(%("one"), %("two")))
        Punch::Spec.eventually(90.seconds) { log.to_s.should contain("punch dev: rebuilding") }
        File.write("src/tiny.cr", source.sub(%("one"), %("three")))
        wait_for(port, "three", log)

        Punch::Spec.eventually(10.seconds) { File.read_lines("tmp/punch-dev/rounds.jsonl").size.should eq(3) }
        rounds = File.read_lines("tmp/punch-dev/rounds.jsonl").map { |line| JSON.parse(line) }
        rounds.map(&.["tier"].as_s).should eq(%w[first full full])
        rounds[1]["edits"].as_a.map { |edit| {edit["path"], edit["kind"], edit["change"]} }.should eq([{"src/tiny.cr", "library", "structure"}])
        rounds.all?(&.["built"].as_bool).should be_true
        rounds[0].dig("stats", "groups", "typing").as_f.should be > 0
      ensure
        dev.stop
        done.receive
      end
    end
  end

  it "needs no build when only an asset's contents changed, but does for a new asset" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do |directory|
      Dir.mkdir_p("app/assets")
      File.write("app/assets/app.css", "a {}")
      port = AppFixture.free_port
      settings = Punch::AppConfig.new(storage: "#{directory}/storage", port: port)
      project = Punch::CLI::Project.load.as(Punch::CLI::Project)
      log = AppFixture::Log.new
      dev = Punch::CLI::DevLoop.new(project, settings, log, poll: 50.milliseconds, env: {"PUNCH_PORT" => port.to_s})
      done = Channel(Nil).new
      spawn { dev.run; done.send(nil) }
      begin
        wait_for(port, "one", log)
        File.write("app/assets/app.css", "b {}")
        Punch::Spec.eventually(10.seconds) { log.to_s.should contain("punch dev: no build needed: app/assets/app.css") }
        File.write("app/assets/more.css", "c {}")
        Punch::Spec.eventually(90.seconds) { log.to_s.scan("punch dev: round ").size.should eq(2) }
        log.to_s.should contain("round 3 (full)")
        rounds = File.read_lines("tmp/punch-dev/rounds.jsonl").map { |line| JSON.parse(line) }
        {rounds[1]["tier"], rounds[1]["skipped"], rounds[1]["built"]}.should eq({"none", true, false})
      ensure
        dev.stop
        done.receive
      end
    end
  end

  it "keeps its own object cache beside Crystal's" do
    Punch::CLI::DevLoop.cache_directory.should end_with("-punch-dev")
  end

  it "notices added and removed files, but not the files a round writes" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      before = Punch::CLI::DevLoop.snapshot
      before.keys.should eq(["src/tiny.cr", "shard.yml"])
      File.write("src/extra.cr", "")
      Dir.mkdir_p("tmp/punch-dev")
      File.write("tmp/punch-dev/app", "")
      Punch::CLI::DevLoop.snapshot.keys.sort!.should eq(["shard.yml", "src/extra.cr", "src/tiny.cr"])
    end
  end
end

describe Punch::CLI::Project do
  it "retries a build once when only linking failed" do
    Punch::CLI::Project.link_failure?("/usr/bin/ld: x.o: undefined reference to `*Foo#bar'").should be_true
    Punch::CLI::Project.link_failure?("Error: execution of command failed with exit status 1: cc \"${@}\" -o app").should be_true
    Punch::CLI::Project.link_failure?("Error: undefined constant Foo").should be_false
  end

  it "reads name, version, and targets from shard.yml" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      project = Punch::CLI::Project.load.as(Punch::CLI::Project)
      {project.name, project.version, project.targets, project.main}.should eq({"tiny", "0.1.0", [{"tiny", "src/tiny.cr"}], "src/tiny.cr"})
      File.write("shard.yml", "name: tiny\nversion: 0.1.0\n")
      Punch::CLI::Project.load.as(Punch::CLI::Failure).code.should eq("no_app")
    end
  end
end

describe Punch::CLI::Commands::DevRounds do
  it "summarizes the logged rounds per tier, and fails without any" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      stdout = IO::Memory.new
      Punch::CLI.run(["dev:rounds", "--json"], stdout, IO::Memory.new, Punch::CLI::TOOL_COMMANDS).should eq(1)
      JSON.parse(stdout.to_s)["error"]["code"].should eq("no_rounds")

      Dir.mkdir_p("tmp/punch-dev")
      round = ->(tier : String, build : Float64, typing : Float64) do
        {round: 1, tier: tier, built: true, build_seconds: build, boot_seconds: 0.05,
         stats: {groups: {typing: typing, ir: 1.0, objects: 0.5, link: 0.25}, reuse: "some", rebuilt: ["A"]}}.to_json
      end
      File.write("tmp/punch-dev/rounds.jsonl", [round.call("first", 9.0, 3.0), round.call("fast", 4.0, 2.0), round.call("fast", 6.0, 4.0), round.call("full", 8.0, 3.0)].join('\n') + "\nnot json\n")
      File.write("tmp/punch-dev/typecheck.jsonl", %({"success": true, "seconds": 1.5, "stats": {"groups": {"typing": 1.4}}}\n))
      stdout = IO::Memory.new
      Punch::CLI.run(["dev:rounds", "--json"], stdout, IO::Memory.new, Punch::CLI::TOOL_COMMANDS).should eq(0)
      summary = JSON.parse(stdout.to_s)
      summary["rounds"].should eq(3)
      fast = summary["tiers"].as_a.find! { |tier| tier["tier"] == "fast" }
      {fast["rounds"], fast["share"], fast["build_seconds"], fast["groups"]["typing"], fast["rebuilt_modules"]}.should eq({2, 0.667, 5.0, 3.0, 1.0})
      summary["typecheck"]["seconds"].should eq(1.5)
      summary["bareknuckle"]?.should be_nil

      built = ->(number : Int32, path : String, build : Float64, refused : String?) do
        {round: number, tier: "fast", built: true, build_seconds: build, path: path, refused: refused,
         stats: {groups: {typing: 0.1, ir: 0.1, objects: 0.1, link: 0.5}}}.to_json
      end
      File.write("tmp/punch-dev/rounds.jsonl", [
        built.call(2, "fast", 1.0, nil), built.call(3, "fast", 2.0, nil), built.call(4, "bareknuckle", 9.0, "code outside methods moved"),
        built.call(5, "bareknuckle", 11.0, "code outside methods moved"), built.call(6, "crystal", 10.0, nil),
      ].join('\n') + "\n")
      File.write("tmp/punch-dev/verify.jsonl", [{round: 2, mismatches: [] of String}, {round: 3, mismatches: ["S-hapes.o0.bc: *Shapes::size:Int32"]}].map(&.to_json).join('\n') + "\n")
      stdout = IO::Memory.new
      Punch::CLI.run(["dev:rounds", "--json"], stdout, IO::Memory.new, Punch::CLI::TOOL_COMMANDS).should eq(0)
      daemon = JSON.parse(stdout.to_s)["bareknuckle"]
      daemon["paths"].as_h.transform_values { |path| {path["rounds"].as_i, path["build_seconds"].as_f} }.should eq({
        "fast" => {2, 1.5}, "bareknuckle" => {2, 10.0}, "crystal" => {1, 10.0},
      })
      daemon["refusals"].as_h.transform_values(&.as_i).should eq({"code outside methods moved" => 2})
      {daemon["verified"], daemon["differed"]}.should eq({2, [3]})
    end
  end
end

describe Punch::Bareknuckle::Daemon do
  it "builds only when asked for, with --bareknuckle or PUNCH_BAREKNUCKLE=on" do
    none = {} of String => String
    Punch::CLI::Commands::Dev.bareknuckle?([] of String, none).should be_false
    Punch::CLI::Commands::Dev.bareknuckle?([] of String, {"PUNCH_BAREKNUCKLE" => "off"}).should be_false
    Punch::CLI::Commands::Dev.bareknuckle?([] of String, {"PUNCH_BAREKNUCKLE" => "on"}).should be_true
    args = ["--bareknuckle"]
    Punch::CLI::Commands::Dev.bareknuckle?(args, none).should be_true
    args.should be_empty
  end

  it "says why it does not start when it is not built" do
    unless File.exists?(Punch::Bareknuckle::Daemon::BINARY)
      Punch::Bareknuckle::Daemon.start("src/main.cr", ["-Dpunch_dev"], "app", nil, "cache").as(String).should contain("punch bareknuckle:build")
    end
  end

  it "has no status for punch typecheck without a daemon" do
    AppFixture.copy("spec/cli/fixture/tiny", shards: [] of String) do
      Punch::Bareknuckle::Daemon.status.should be_nil
    end
  end
end
