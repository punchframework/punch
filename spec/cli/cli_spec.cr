require "../spec_helper"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args, commands = Punch::CLI::COMMANDS) : Run
  argv = [] of String
  args.each { |arg| argv << arg }
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(argv, stdout, stderr, commands)
  Run.new(code, stdout.to_s, stderr.to_s)
end

# Runs the block in a fresh empty directory. Examples run one at a time, so
# changing the working directory is safe here.
private def in_empty_directory(& : -> T) : T forall T
  directory = File.tempname("punch-empty")
  Dir.mkdir(directory)
  begin
    Dir.cd(directory) { yield }
  ensure
    FileUtils.rm_rf(directory)
  end
end

# The `punch` binary, built in the background while other specs run, for the
# specs that run it as a process.
private module PunchBinary
  BUILT = Channel(String).new(1)
  @@path : String?
  @@lock = Mutex.new

  def self.start : Nil
    spawn do
      binary = File.tempname("punch-cli")
      status = Process.run("crystal", ["build", "#{__DIR__}/../../src/cli/main.cr", "-o", binary],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      BUILT.send(status.success? ? binary : "")
    end
  end

  def self.path : String
    @@lock.synchronize { @@path ||= BUILT.receive }.presence || fail "building the punch binary failed"
  end
end

PunchBinary.start
Spec.after_suite { File.delete?(PunchBinary.path) rescue nil }

private def punch_binary : String
  PunchBinary.path
end

private class Explodes < Punch::CLI::Command
  command "explode", "Raises, to test bug reporting"

  def run(args : Array(String)) : Punch::CLI::Report | Punch::CLI::Failure
    raise "boom"
  end
end

describe Punch::CLI do
  describe "--json convention" do
    # Every command of the standalone binary and of application binaries.
    all_commands = (Punch::CLI::TOOL_COMMANDS + Punch::CLI::APP_COMMANDS).uniq

    all_commands.select(&.json?).each do |command|
      it "'#{command.command_name}' writes exactly one JSON document and nothing to stderr" do
        # In an empty directory, so no command finds an app to work on.
        run = in_empty_directory { punch(command.command_name, "--json", commands: all_commands) }
        run.stderr.should be_empty
        run.stdout.lines.size.should eq(1)
        document = JSON.parse(run.stdout)
        document.as_h?.should_not be_nil

        # A command that needs an argument answers with a usage error, one
        # that needs an app (here, the repository has none) with a failure.
        case run.code
        when 2 then document["error"]["code"].should eq("missing_argument")
        when 1 then document["error"]["code"].as_s.should_not be_empty
        else        run.code.should eq(0)
        end
      end
    end

    all_commands.reject(&.json?).each do |command|
      it "'#{command.command_name}' is interactive and answers --json with one JSON usage error" do
        run = punch(command.command_name, "some.db", "--json", commands: all_commands)
        run.code.should eq(2)
        run.stderr.should be_empty
        JSON.parse(run.stdout)["error"]["code"].should eq("no_json_mode")
      end
    end

    it "accepts --json in any position" do
      punch("--json", "version").stdout.should eq(punch("version", "--json").stdout)
    end

    it "reports usage errors as a JSON error with exit code 2" do
      run = punch("nope", "--json")
      run.code.should eq(2)
      run.stderr.should be_empty
      JSON.parse(run.stdout)["error"]["code"].should eq("unknown_command")
    end

    it "reports a raised exception as internal_error with exit code 1" do
      run = punch("explode", "--json", commands: [Explodes] of Punch::CLI::Command.class)
      run.code.should eq(1)
      JSON.parse(run.stdout)["error"]["code"].should eq("internal_error")
      run.stderr.should contain("boom")
    end
  end

  describe "routes" do
    it "is a command of application binaries only" do
      punch("routes").code.should eq(2)
      punch(commands: Punch::CLI::APP_COMMANDS).stdout.should contain("routes")
    end

    it "lists every derived route as JSON" do
      run = punch("routes", "--json", commands: Punch::CLI::APP_COMMANDS)
      routes = JSON.parse(run.stdout)["routes"].as_a
      routes.size.should eq(Punch::Routing.routes.size)
      routes.each do |route|
        keys = %w[method path operation operation_id kind surfaces]
        keys << "form_page" if route["form_page"]?
        keys.concat(%w[actor rate_limits])
        keys << "rate_limit_exempt" if route["rate_limit_exempt"]?
        keys.concat(%w[policy public unlisted entry])
        route.as_h.keys.should eq(keys)
      end
      routes.map(&.["policy"].as_s?).should eq(Punch::Routing.routes.sort_by { |route| {route.template, route.method, route.kind.value} }.map(&.policy))
      routes.map(&.["form_page"]?.try(&.as_s)).should eq(Punch::Routing.routes.sort_by { |route| {route.template, route.method, route.kind.value} }.map(&.form_page))
    end

    it "lists one route per line as text" do
      run = punch("routes", commands: Punch::CLI::APP_COMMANDS)
      Punch::Routing.routes.each do |route|
        form = route.form_page.try { |page| "  \\(form on #{page}\\)" }
        policy = route.policy.try { |name| "  \\(policy: #{Regex.escape(name)}\\)" } || (route.public ? "  \\(public\\)" : "")
        limited = route.rate_limits.empty? ? "" : "  \\(limited: #{Regex.escape(route.rate_limits.join(", ", &.name))}\\)"
        unlisted = route.unlisted ? "  \\(unlisted\\)" : ""
        entry = route.entry ? "  \\(entry point\\)" : ""
        run.stdout.should match(/^#{route.method} +#{Regex.escape(route.template)} +#{route.surfaces.join(',')} +#{route.operation}#{form}#{policy}#{limited}#{unlisted}#{entry}$/m)
      end
    end
  end

  describe "text mode" do
    it "prints help when called without a command" do
      run = punch
      run.code.should eq(0)
      run.stdout.should contain("Usage: punch")
      Punch::CLI::COMMANDS.each { |command| run.stdout.should contain(command.command_name) }
    end

    it "writes failures to stderr only" do
      run = punch("nope")
      run.code.should eq(2)
      run.stdout.should be_empty
      run.stderr.should contain("Unknown command 'nope'")
    end

    it "rejects arguments to commands that take none" do
      run = punch("version", "extra")
      run.code.should eq(2)
      run.stderr.should contain("takes no arguments")
    end
  end

  describe "db" do
    it "reports the linked SQLite" do
      sqlite = JSON.parse(punch("db", "--json").stdout)["sqlite"]
      sqlite["version"].should eq(Punch::Database::Driver.version)
      sqlite["compile_options"].as_a.map(&.as_s).should contain("THREADSAFE=1")
    end

    it "reports a database file without changing it" do
      Punch::Spec.database(file: true) do |db|
        db.write { |writer| writer.exec("CREATE TABLE t (id INTEGER PRIMARY KEY) STRICT"); writer.exec("PRAGMA user_version = 7") }
        run = punch("db", db.path, "--json")
        run.code.should eq(0)
        database = JSON.parse(run.stdout)["database"]
        database["path"].should eq(db.path)
        database["filesystem"]["refused"].should be_false
        database["pragmas"]["journal_mode"].should eq("wal")
        database["pragmas"]["user_version"].should eq("7")
        punch("db", db.path).stdout.should match(/^  journal_mode: wal$/m)
      end
    end

    it "reports the collations it has and the versions a file's indexes were built with" do
      document = JSON.parse(punch("db", "--json").stdout)
      document["collations"].as_a.map(&.["name"].as_s).should eq(%w[de en es fr it nl pt])
      Punch::Spec.database(file: true) do |db|
        db.write do |writer|
          writer.exec("CREATE TABLE punch_collations (name TEXT PRIMARY KEY, version TEXT NOT NULL) STRICT")
          writer.exec("INSERT INTO punch_collations VALUES ('de', ?), ('fr', 'old')", Punch::Text::Collation::Latin::VERSION)
        end
        collations = JSON.parse(punch("db", db.path, "--json").stdout)["database"]["collations"].as_a
        collations.map { |entry| {entry["name"].as_s, entry["changed"].as_bool} }.should eq([{"de", false}, {"fr", true}])
        punch("db", db.path).stdout.should contain("  collation fr: old (changed: this binary has #{Punch::Text::Collation::Latin::VERSION}; REINDEX fr in a migration)")
      end
    end

    it "fails for a missing file instead of creating it" do
      path = File.tempname("punch-missing", ".db")
      run = punch("db", path, "--json")
      run.code.should eq(1)
      JSON.parse(run.stdout)["error"]["code"].should eq("not_found")
      File.exists?(path).should be_false
    end
  end

  describe "db:shell" do
    it "runs the vendored shell on a database" do
      Punch::Spec.database(file: true) do |db|
        db.write { |writer| writer.exec("CREATE TABLE t (name TEXT NOT NULL) STRICT"); writer.exec("INSERT INTO t VALUES ('Ada')") }
        output = IO::Memory.new
        status = Process.run(punch_binary, ["db:shell", db.path, "SELECT name, sqlite_version() FROM t"], output: output, error: output)
        status.success?.should be_true
        output.to_s.should eq("Ada|#{Punch::Database::Driver.version}\n")
      end
    end

    it "registers Punch's collations and text functions" do
      Punch::Spec.database(file: true) do |db|
        db.write do |writer|
          writer.exec("CREATE TABLE t (name TEXT NOT NULL COLLATE de) STRICT")
          writer.exec("INSERT INTO t VALUES ('zulu'), ('Ärger'), ('apfel')")
        end
        output = IO::Memory.new
        Process.run(punch_binary, ["db:shell", db.path, "SELECT group_concat(name, ' ') FROM (SELECT name FROM t ORDER BY name); SELECT upper('straße'), 'ÄRGER' LIKE 'ä%'"],
          output: output, error: output).success?.should be_true
        output.to_s.should eq("apfel Ärger zulu\nSTRASSE|1\n")
      end
    end

    it "reads SQL from standard input" do
      Punch::Spec.database(file: true) do |db|
        output = IO::Memory.new
        input = IO::Memory.new(".mode json\nSELECT 1 AS one;\n")
        Process.run(punch_binary, ["db:shell", db.path], input: input, output: output, error: output).success?.should be_true
        JSON.parse(output.to_s).should eq(JSON.parse(%([{"one":1}])))
      end
    end

    it "does not create a missing file" do
      path = File.tempname("punch-missing", ".db")
      punch("db:shell", path).code.should eq(1)
      File.exists?(path).should be_false
    end
  end

  describe "version" do
    it "reports the Punch, Crystal, SQLite, and OpenSSL versions" do
      JSON.parse(punch("version", "--json").stdout).should eq(
        JSON.parse({punch: Punch::VERSION, crystal: Crystal::VERSION, sqlite: Punch::Database::Driver.version, openssl: LibCrypto::OPENSSL_VERSION}.to_json))
      punch("--version").stdout.should eq("punch #{Punch::VERSION} (Crystal #{Crystal::VERSION}, SQLite #{Punch::Database::Driver.version}, OpenSSL #{LibCrypto::OPENSSL_VERSION})\n")
    end
  end
end
