require "../spec_helper"
require "http/client"
require "../support/app_fixture"
require "../../src/punch/cli/tool"

private def punch(*args : String) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::TOOL_COMMANDS)
  {code, stdout.to_s, stderr.to_s}
end

# The app's own spec: every operation through the in-process client, each
# response checked against the openapi.json `punch openapi` derived.
private APP_SPEC = <<-CRYSTAL
  require "punch/spec"
  require "../src/shop"

  describe "the shop" do
    it "keeps its contract" do
      client = Punch::Spec.client
      client.contract.should_not be_nil
      client.get(Shop::Invoices::Index.path).json.should eq(JSON.parse("[]"))
      client.get(Shop::Invoices::Index.path, query: {state: "sent", limit: 5}).status.code.should eq(200)
      client.get(Shop::Invoices::Index.path, query: {limit: "many"}).json["code"].should eq("invalid_input")
      client.get("/shop/invoices/1").json["code"].should eq("not_found")
      client.post(Shop::Invoices::Create.path, json: {number: "inv-1", recipient: "ann@example.org"}).json["id"].should eq(1)
      client.post(Shop::Invoices::Create.path, json: {number: "Inv 1"}).status.code.should eq(422)
      client.post("/shop/invoices/1/send").status.code.should eq(204)
      client.delete("/shop/invoices/1").status.code.should eq(405)
      one = Shop::Invoices::ID.parse(1).as(Shop::Invoices::ID)
      client.visit(Shop::Invoices::ShowPage.href(invoice_id: one)).should have_element("h1", text: "Invoice 1")
      client.submit(Shop::Invoices::Send.action(invoice_id: one)).should redirect_to(Shop::Invoices::ShowPage.href(invoice_id: one))
      client.visit("/shop/invoices/2").status.code.should eq(404)
    end
  end
  CRYSTAL

# Credentials the shop declares, added to the fixture at test time.
private CREDENTIALS = <<-CRYSTAL
  struct Shop::Credentials
    include Punch::Credentials

    getter payments : Payments
    getter? sandbox : Bool = true

    struct Payments
      include Punch::Credentials
      getter api_key : Punch::Secret(String)
    end
  end

  Punch.credentials Shop::Credentials
  CRYSTAL

describe "an app built with Punch" do
  it "lists its routes, passes its contract specs, and serves with settings from the environment" do
    AppFixture.copy("spec/openapi/fixture") do
      File.write("src/credentials.cr", CREDENTIALS)
      File.write("src/main.cr", File.read("src/main.cr").sub(%(require "./shop"\n), %(require "./shop"\nrequire "./credentials"\nPunch.migrations "../db/migrations"\n)))
      Dir.mkdir_p("db/migrations")
      # Every app has the table jobs in steps save their progress in.
      File.write("db/migrations/20261019090000_create_notes.sql",
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT;\n#{Punch::Job::Steps::Progress.sql}")
      punch("creds:init", "--env", "production")[0].should eq(0)
      set = Punch::CLI::Commands::CredsSet.new(Punch::CLI::TOOL_COMMANDS)
      set.input = IO::Memory.new("pk_live_shop\n")
      set.run(["payments.api_key", "--env", "production"]).should be_a(Punch::CLI::Report)
      openapi = punch("openapi")
      fail openapi.inspect unless openapi[0] == 0

      code, stdout, stderr = punch("routes")
      {code, stderr}.should eq({0, ""})
      stdout.should eq(<<-TEXT)
        GET   /shop/invoices                   json                Shop::Invoices::Index
        POST  /shop/invoices                   json                Shop::Invoices::Create
        GET   /shop/invoices/:invoice_id       json                Shop::Invoices::Show
        GET   /shop/invoices/:invoice_id       html                Shop::Invoices::ShowPage
        POST  /shop/invoices/:invoice_id/send  json,html,markdown  Shop::Invoices::Send  (form on Shop::Invoices::ShowPage)

        TEXT
      routes = JSON.parse(punch("routes", "--json")[1])["routes"]
      routes[0]["operation_id"].should eq("shop.invoices.index")
      {routes[3]["operation"], routes[3]["kind"], routes[3]["surfaces"]}.should eq({"Shop::Invoices::ShowPage", "page", ["html"]})
      routes[4]["form_page"].should eq("Shop::Invoices::ShowPage")

      Dir.mkdir("spec")
      File.write("spec/shop_spec.cr", APP_SPEC)
      output = IO::Memory.new
      status = Process.run("crystal", ["spec", "--no-color"], output: output, error: output)
      fail output.to_s unless status.success?
      output.to_s.should contain("1 examples, 0 failures")

      # The binary `punch routes` built embeds openapi.json and serves.
      port = AppFixture.free_port
      storage = File.tempname("punch-storage")
      # No replica here: in production, /up fails without one unless the
      # files are exempted (docs/backup.md).
      env = {"PUNCH_PORT" => port.to_s, "PUNCH_STORAGE" => storage, "PUNCH_TRACE" => "off", "PUNCH_ENV" => "production",
             "PUNCH_PUBLIC_URL" => "https://shop.example.org", "PUNCH_BACKUP_EXEMPT" => "primary,queue,ops"}

      # Credentials are checked before anything starts: development has no
      # file, so the required key is missing.
      refused = IO::Memory.new
      status = Process.run(Punch::CLI::Commands::ToolRoutes::BINARY, ["serve"], env: env.merge({"PUNCH_ENV" => "development"}), output: refused, error: refused)
      status.exit_code.should eq(1)
      refused.to_s.should eq(<<-TEXT)
        app: The credentials for development have problems:
          payments.api_key is missing: set PAYMENTS__API_KEY or add it to config/credentials/development.yml.enc

        TEXT
      Dir.exists?(storage).should be_false

      # The production file is compiled in; its key is read at runtime.
      check = IO::Memory.new
      Process.run(Punch::CLI::Commands::ToolRoutes::BINARY, ["creds:check", "--env", "production", "--json"], env: {"SANDBOX" => "false"}, output: check)
      JSON.parse(check.to_s).should eq(JSON.parse(<<-JSON))
        {"declared": true, "environment": "production", "file": "config/credentials/production.yml.enc",
         "key": "config/credentials/production.key",
         "credentials": [
           {"path": "payments.api_key", "origin": "file", "where": "payments.api_key in config/credentials/production.yml.enc", "secret": true, "value": null},
           {"path": "sandbox", "origin": "environment", "where": "SANDBOX", "secret": false, "value": "false"}]}
        JSON
      check.to_s.should_not contain("pk_live")

      # The binary carries its migrations: with PUNCH_MIGRATE=off it
      # refuses while they are pending, and its db:status needs no source
      # tree.
      binary = File.expand_path(Punch::CLI::Commands::ToolRoutes::BINARY)
      refused = IO::Memory.new
      Process.run(binary, ["serve"], env: env.merge({"PUNCH_MIGRATE" => "off"}), output: refused, error: refused).exit_code.should eq(1)
      refused.to_s.should eq("app: #{storage}/primary.db lacks 1 migration(s) of this binary: 20261019090000_create_notes.sql. " \
                             "Run db:migrate first, or start with PUNCH_MIGRATE=on.\n")
      status = IO::Memory.new
      Process.run(binary, ["db:status", "#{storage}/primary.db", "--json"], chdir: storage, output: status)
      JSON.parse(status.to_s)["migrations"].as_a.map(&.["state"]).should eq(["pending"])

      log = IO::Memory.new
      app = Process.new(Punch::CLI::Commands::ToolRoutes::BINARY, ["serve"], env: env, output: log, error: log)
      begin
        Punch::Spec.eventually(20.seconds) do
          up = (HTTP::Client.get("http://127.0.0.1:#{port}/up") rescue nil)
          up.try(&.status_code).should eq(200)
        end
        HTTP::Client.get("http://127.0.0.1:#{port}/openapi.json").body.should eq(File.read("openapi.json"))
        HTTP::Client.get("http://127.0.0.1:#{port}/shop/invoices").body.should eq("[]")
        File.exists?("#{storage}/primary.db").should be_true
        # serve applied the binary's migration at boot.
        status = IO::Memory.new
        Process.run(binary, ["db:status", "--json"], env: env, chdir: storage, output: status)
        JSON.parse(status.to_s)["migrations"].as_a.map { |entry| {entry["name"].as_s, entry["state"].as_s} }.should eq([{"create_notes", "applied"}])
        log.to_s.should contain("applied 20261019090000_create_notes.sql")
        File.exists?("#{storage}/cache.db").should be_true
        File.exists?("#{storage}/queue.db").should be_true
        File.exists?("#{storage}/ops.db").should be_true
        errors = IO::Memory.new
        Process.run(Punch::CLI::Commands::ToolRoutes::BINARY, ["ops:errors", "--json"], env: env, output: errors)
        JSON.parse(errors.to_s).should eq(JSON.parse(%({"errors": []})))
        # The jobs process: no HTTP, a heartbeat in queue.db, a clean stop.
        jobs_log = IO::Memory.new
        jobs = Process.new(Punch::CLI::Commands::ToolRoutes::BINARY, ["jobs"], env: env.merge({"PUNCH_JOB_QUEUES" => "mail"}), output: jobs_log, error: jobs_log)
        begin
          Punch::Spec.eventually(10.seconds) do
            stats = IO::Memory.new
            Process.run(Punch::CLI::Commands::ToolRoutes::BINARY, ["jobs:stats", "--json"], env: env, output: stats)
            JSON.parse(stats.to_s)["processes"].as_a.map { |process| {process["kind"].as_s, process["queues"].as_s} }.sort!.should eq(
              [{"jobs", "mail"}, {"serve", "*"}])
          end
        ensure
          jobs.signal(Signal::TERM)
          jobs.wait.success?.should be_true
        end
        jobs_log.to_s.should contain("claiming from mail")
      ensure
        app.signal(Signal::TERM)
        app.wait.success?.should be_true
        FileUtils.rm_rf(storage)
      end
    end
  end
end

describe "punch config" do
  it "shows the settings from the environment, and every problem with them" do
    {"PUNCH_STORAGE" => "/var/lib/shop", "PUNCH_PORT" => "8080", "PUNCH_TRUSTED_PROXIES" => "10.0.0.0/8, 192.168.1.1", "PUNCH_THREADS" => "6"}.each { |key, value| ENV[key] = value }
    begin
      code, stdout, _ = punch("config", "--json")
      code.should eq(0)
      JSON.parse(stdout).should eq(JSON.parse(<<-JSON))
        {"environment": "development", "storage": "/var/lib/shop", "primary_database": "/var/lib/shop/primary.db", "host": "127.0.0.1", "port": 8080,
         "public_url": "http://127.0.0.1:8080", "trusted_proxies": ["10.0.0.0/8", "192.168.1.1"], "trusted_origins": [],
         "drain_delay_seconds": 0, "shutdown_timeout_seconds": 25, "migrate": true, "threads": 6, "trace": "json",
         "trace_sample_percent": 100, "otlp": null,
         "backup": {"url": null, "exempt": [], "encryption": "check", "litestream": "litestream"},
         "cache": true, "cache_mb": 256, "jobs": true, "job_threads": 2, "job_concurrency": 10, "job_queues": null, "job_retention_hours": 72,
         "ops": true, "ops_sample_percent": 100, "ops_retention_days": 14, "ops_slow_ms": 500, "idempotency_retention_hours": 24, "webhook_retention_days": 30,
         "probes": {"enabled": true, "ban_after": 2, "window_minutes": 10, "bans_seconds": [3600, 86400, 604800], "allow": []},
         "limits": {"primary": {"length": 33554432, "sql_length": 1048576, "parser_depth": 500, "trigger_depth": 32, "variable_number": 1000, "schema": 10000, "trigger_steps": 100, "like_pattern_length": 50000}, "cache": {"length": 33554432, "sql_length": 1048576, "parser_depth": 500, "trigger_depth": 32, "variable_number": 1000, "schema": 10000, "trigger_steps": 100, "like_pattern_length": 50000}, "queue": {"length": 33554432, "sql_length": 1048576, "parser_depth": 500, "trigger_depth": 32, "variable_number": 1000, "schema": 10000, "trigger_steps": 100, "like_pattern_length": 50000}, "ops": {"length": 33554432, "sql_length": 1048576, "parser_depth": 500, "trigger_depth": 32, "variable_number": 1000, "schema": 10000, "trigger_steps": 100, "like_pattern_length": 50000}}}
        JSON
      ENV["PUNCH_PORT"] = "eighty"
      ENV["PUNCH_TRACE"] = "loud"
      ENV["PUNCH_THREADS"] = "0"
      ENV["PUNCH_DRAIN_DELAY_SECONDS"] = "-1"
      ENV["PUNCH_MIGRATE"] = "later"
      ENV["PUNCH_ENV"] = "Production"
      ENV["PUNCH_CACHE"] = "maybe"
      ENV["PUNCH_CACHE_MB"] = "0"
      ENV["PUNCH_JOBS"] = "sometimes"
      ENV["PUNCH_JOB_CONCURRENCY"] = "0"
      ENV["PUNCH_JOB_QUEUES"] = "mail, Bulk"
      ENV["PUNCH_OPS"] = "always"
      ENV["PUNCH_OPS_SAMPLE_PERCENT"] = "101"
      ENV["PUNCH_BACKUP_EXEMPT"] = "cache"
      code, _, stderr = punch("config")
      code.should eq(1)
      stderr.should eq(<<-TEXT)
        punch: The environment has invalid settings:
          PUNCH_ENV must be lowercase letters, digits, and _, got "Production"
          PUNCH_PORT must be a port number from 1 to 65535, got "eighty"
          PUNCH_DRAIN_DELAY_SECONDS must be a number of seconds from 0 to 300, got "-1"
          PUNCH_MIGRATE must be on or off, got "later"
          PUNCH_THREADS must be a number from 1 to 1024, got "0"
          PUNCH_TRACE must be json, console, or off, got "loud"
          PUNCH_BACKUP_EXEMPT: "cache" is not a replicated file (primary, queue, ops)
          PUNCH_CACHE must be on or off, got "maybe"
          PUNCH_CACHE_MB must be a size in MiB from 1 to 1048576, got "0"
          PUNCH_JOBS must be on or off, got "sometimes"
          PUNCH_JOB_CONCURRENCY must be a number from 1 to 10000, got "0"
          PUNCH_JOB_QUEUES: "Bulk" is not a queue name (lowercase letters, digits, and _)
          PUNCH_OPS must be on or off, got "always"
          PUNCH_OPS_SAMPLE_PERCENT must be a percentage from 0 to 100, got "101"

        TEXT
    ensure
      Punch::AppConfig::VARIABLES.each { |key| ENV.delete(key) }
    end
  end

  it "exports traces and metrics over OTLP when an endpoint is set" do
    Punch::AppConfig.from({} of String => String).as(Punch::AppConfig).otlp.should be_nil
    settings = Punch::AppConfig.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "http://127.0.0.1:9", "PUNCH_TRACE_SAMPLE_PERCENT" => "10",
                                      "OTEL_METRIC_EXPORT_INTERVAL" => "1000"}).as(Punch::AppConfig)
    settings.trace_sample_percent.should eq(10)
    otlp = settings.otlp.should_not be_nil
    otlp.traces.to_s.should eq("http://127.0.0.1:9/v1/traces")
    tracer = settings.tracer
    tracer.exporters.map(&.class).should eq([Punch::OTLP::TraceExporter])
    tracer.sample_ratio.should eq(0.1)
    tracer.close
    settings.metric_exporter.should be_a(Punch::OTLP::MetricExporter)
    problems = Punch::AppConfig.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "ftp://x", "PUNCH_TRACE_SAMPLE_PERCENT" => "200"}).as(Array(String))
    problems.should eq(["PUNCH_TRACE_SAMPLE_PERCENT must be a percentage from 0 to 100, got \"200\"",
                        "OTEL_EXPORTER_OTLP_ENDPOINT must be an http or https URL, such as http://localhost:4318, got \"ftp://x\""])
  end

  it "refuses trusted proxies that would trust everyone" do
    # A refused URL is shown without its credentials and query.
    leaky = Punch::AppConfig.from({"OTEL_EXPORTER_OTLP_ENDPOINT" => "https://user:FIXTURESECRET@otlp.example/?key=FIXTUREKEY",
                                   "PUNCH_BACKUP_URL"            => "https://AKIAFIXTURE:FIXTURESECRET@bucket.example/app"}).as(Array(String))
    leaky.size.should eq(2)
    leaky.join.should_not contain("FIXTURE")
    leaky.join.should contain(%("https://…@otlp.example/?…"))
    Punch::AppConfig.from({"PUNCH_TRUSTED_PROXIES" => "0.0.0.0/0"}).as(Array(String)).first.should start_with("PUNCH_TRUSTED_PROXIES: ")
    # serve and jobs: a missing PUNCH_ENV would read as development.
    Punch::AppConfig.from({} of String => String, require_env: true).as(Array(String)).first.should start_with("PUNCH_ENV is not set")
    Punch::AppConfig.from({"PUNCH_ENV" => "development"}, require_env: true).should be_a(Punch::AppConfig)
    defaults = Punch::AppConfig.from({} of String => String).as(Punch::AppConfig)
    defaults.primary_database.should eq("storage/primary.db")
    defaults.threads.should eq(Fiber::ExecutionContext.default_workers_count)
    {defaults.cache?, defaults.cache_bytes}.should eq({true, 256_i64 * 1024 * 1024})
    {defaults.http.drain_delay, defaults.http.shutdown_timeout, defaults.migrate?}.should eq({0.seconds, 25.seconds, true})
    drained = Punch::AppConfig.from({"PUNCH_DRAIN_DELAY_SECONDS" => "5", "PUNCH_SHUTDOWN_TIMEOUT_SECONDS" => "50"}).as(Punch::AppConfig)
    {drained.http.drain_delay, drained.http.shutdown_timeout}.should eq({5.seconds, 50.seconds})
    Punch::AppConfig.from({"PUNCH_CACHE" => "off", "PUNCH_CACHE_MB" => "16"}).as(Punch::AppConfig).cache_bytes.should eq(16 * 1024 * 1024)
    {defaults.jobs?, defaults.job_queues, defaults.worker.concurrency, defaults.worker.threads}.should eq({true, nil, 10, 2})
    jobs = Punch::AppConfig.from({"PUNCH_JOBS" => "off", "PUNCH_JOB_QUEUES" => "mail,bulk", "PUNCH_JOB_THREADS" => "4"}).as(Punch::AppConfig)
    {jobs.jobs?, jobs.worker.queues, jobs.worker.threads}.should eq({false, %w[mail bulk], 4})
    Punch::AppConfig.from({"PUNCH_JOB_QUEUES" => "*"}).as(Punch::AppConfig).job_queues.should be_nil
    {defaults.ops?, defaults.ops_sample_percent, defaults.ops_retention}.should eq({true, 100, 14.days})
    ops = Punch::AppConfig.from({"PUNCH_OPS" => "off", "PUNCH_OPS_SAMPLE_PERCENT" => "5", "PUNCH_OPS_RETENTION_DAYS" => "90"}).as(Punch::AppConfig)
    {ops.ops?, ops.ops_sample_percent, ops.ops_retention}.should eq({false, 5, 90.days})
    defaults.idempotency_retention.should eq(24.hours)
    Punch::AppConfig.from({"PUNCH_IDEMPOTENCY_RETENTION_HOURS" => "48"}).as(Punch::AppConfig).idempotency_retention.should eq(48.hours)
    {defaults.webhook_retention, Punch::AppConfig.from({"PUNCH_WEBHOOK_RETENTION_DAYS" => "7"}).as(Punch::AppConfig).webhook_retention}.should eq({30.days, 7.days})
    # openapi.json promises a day.
    Punch::AppConfig.from({"PUNCH_IDEMPOTENCY_RETENTION_HOURS" => "12"}).as(Array(String)).first.should start_with("PUNCH_IDEMPOTENCY_RETENTION_HOURS must be")
  end
end
