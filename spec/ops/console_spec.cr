require "../spec_helper"
require "../support/auth_schema"
require "../../src/punch/ops/console"
require "../../src/punch/cli/tool"

module ConsoleSpec
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  # A global role that includes the console's, as an app's `Operator`.
  struct Operator
    include Punch::Role

    permits Punch::Ops::Console::Operations
  end

  # Who `ByRole` asks about: an actor with a principal.
  struct RoleActor
    include Punch::Auth::Actor

    record Principal, user_id : Int64

    getter principal : Principal

    def initialize(user_id : Int64)
      @principal = Principal.new(user_id)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal.user_id)
    end
  end

  # An actor with nothing to it, for the default policy.
  struct Anyone
    include Punch::Auth::Actor

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new
    end
  end

  # User 1 operates the app; everyone else learns nothing.
  struct Operators
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, **params) : Punch::Policy::Decision
      actor.principal.user_id == 1 ? allow : not_found
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Explode < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Nil
      raise IndexError.new("exploded")
    end
  end

  @[Punch::Job::Options(queue: "mail", attempts: 1)]
  struct Deliver
    include Punch::Job

    getter to : String

    def initialize(@to)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      raise ArgumentError.new("mailbox full for #{to}")
    end
  end

  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end

  # An open error in this example's ops store, from a request.
  def self.error : Punch::Ops::ErrorGroup
    ops = Punch::Spec.ops
    Punch::Spec.client(raise_errors: false).post(Explode.path).status.code.should eq(500)
    ops.errors.first
  end

  # A failed job in this example's queue.
  def self.failed_job(to : String = "ada@example.org") : Int64
    id = must(Punch::Spec.queue.enqueue(Deliver.new(to)))
    Punch::Spec.perform_jobs
    id
  end

  struct Credentials
    include Punch::Credentials

    getter mail : Punch::Mailer::Settings
  end

  struct Hello
    include Punch::Mail

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(Punch::Email.parse("ada@example.org").as(Punch::Email), "Ada")
    end

    def subject(locale : Punch::Locale) : String
      "Hello <Ada>"
    end

    def view(v : Punch::View) : Nil
      v.p "Dear Ada <script>,"
    end
  end

  TOTALS = Punch::Cache(String, Int32).new("console_totals", ttl: 1.minute, tier: :both)

  struct Noted
    include Punch::Event

    getter tag : String

    def initialize(@tag)
    end
  end

  struct Listener
    include Punch::Subscriber(Noted)

    def call(event : Noted) : Nil
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Note < Punch::Command
    struct Input
      include Punch::Input

      getter tag : String
    end

    def call(input : Input, db : Punch::Writer, events : Punch::Events(Noted)) : Nil
      events.publish(Noted.new(input.tag))
      nil
    end
  end

  @[Punch::Public]
  struct Total < Punch::Query
    struct Input
      include Punch::Input
    end

    struct Counted
      include JSON::Serializable

      getter users : Int64

      def initialize(@users)
      end
    end

    def call(input : Input, db : Punch::Reader) : Counted
      Counted.new(db.query_one?("SELECT count(*) FROM users", name: "ConsoleSpec.users", &.read(Int64)) || 0_i64)
    end
  end

  struct Tick
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      nil
    end
  end

  struct Ping
    include Punch::Input

    getter n : Int64
  end

  @@pings = Atomic(Int32).new(0)

  def self.pings : Int32
    @@pings.get
  end

  def self.pinged : Nil
    @@pings.add(1)
  end

  @[Punch::Webhook::Provider("console", verify: :none)]
  struct Hooks < Punch::Webhook::Inbound
    def parse(request : Punch::RawRequest) : Ping | Punch::Webhook::Ignored | Punch::Webhook::Unprocessable
      case ping = Ping.from_json(request.body)
      in Punch::Rejection then Punch::Webhook::Unprocessable.new("not a ping")
      in Ping             then ping
      end
    end

    def process(event : Ping, db : Punch::Writer) : Punch::Webhook::Outcome
      ConsoleSpec.pinged
      Punch::Webhook::Processed.new
    end
  end

  WEBHOOKS = Punch::Job::Outbox.sql + Punch::Webhook::Invocations.sql

  # A stored invocation of the console provider in *state*.
  def self.invocation(state : String) : Int64
    finished = state.in?("received", "verified") ? nil : 2_000_i64
    error = state == "failed" ? "upstream said no" : nil
    must(Punch::Spec.db.write do |db|
      db.query_one?(<<-SQL, Random::Secure.hex(8), state, %({"n": 1}).to_slice, error, finished, &.read(Int64))
        INSERT INTO punch_webhooks (provider, key, fingerprint, state, body, headers, attempts, error, received_at, verified_at, finished_at)
        VALUES ('console', ?, x'00', ?, ?, '{"webhook-id": "msg_1"}', 1, ?, 1000, 1000, ?)
        RETURNING id
        SQL
    end)
  end

  def self.state(id : Int64) : String
    must(Punch::Spec.db.read { |db| Punch::Webhook::Invocations.stored(db, id) }).listed.state
  end

  def self.operator : Punch::Spec::Client
    Punch::Spec.client.sign_in(1)
  end

  # Runs `punch` with *args* and `--json`, and the JSON it printed.
  def self.cli(*args : String) : {Int32, JSON::Any}
    stdout = IO::Memory.new
    code = Punch::CLI.run(args.to_a + ["--json"], stdout, IO::Memory.new)
    {code, JSON.parse(stdout.to_s)}
  end

  # The app over this example's database on a real socket, for the
  # block, with its address.
  def self.serving(&)
    router = Punch::Routing::Router.new(Punch::Spec.db)
    server = Punch::HTTP::Server.new(Punch::HTTP::Config.new, Punch::Trace::Tracer.off) { |context| router.call(context) }
    port = server.bind(0).port
    stopped = Channel(Nil).new
    spawn { server.run(trap_signals: false); stopped.send(nil) }
    begin
      yield "http://127.0.0.1:#{port}"
    ensure
      server.shutdown
      stopped.receive
    end
  end
end

Punch::Ops::Console.mount ConsoleSpec::Actor, ConsoleSpec::Operators

alias Console = Punch::Ops::Console

describe Punch::Ops::Console do
  describe "access" do
    it "lets the policy's actors in, sends others to sign in, and hides itself from everyone else" do
      AuthSchema.with_spec_db do
        Punch::Spec.ops
        ConsoleSpec.operator.visit(Console::IndexPage.href).status.code.should eq(200)
        Punch::Spec.client.sign_in(2).visit(Console::ErrorsPage.href).status.code.should eq(404)
        Punch::Spec.client.sign_in(2).post(Console::ResolveError.path(error_id: 1_i64)).status.code.should eq(404)
        Punch::Spec.client.visit(Console::IndexPage.href).status.code.should eq(401)
      end
    end

    it "is open, by role, to holders of a global role that includes Operations" do
      AuthSchema.with_spec_db(Punch::Roles::Schema.sql) do
        Punch::Spec.db.write { |db| Punch::Roles.assign(db, 1_i64, ConsoleSpec::Operator) }
        Punch::Spec.db.read do |db|
          Console::ByRole.check(ConsoleSpec::RoleActor.new(1), db, Console::ErrorsPage).should eq(Punch::Policy::Decision::Allow)
          Console::ByRole.check(ConsoleSpec::RoleActor.new(1), db, Console::ConfirmRecovery, error_id: 1_i64).should eq(Punch::Policy::Decision::Allow)
          Console::ByRole.check(ConsoleSpec::RoleActor.new(2), db, Console::ErrorsPage).should eq(Punch::Policy::Decision::NotFound)
        end
      end
    end

    it "lists every console operation in Operations" do
      listed = Punch::Roles.definitions.find!(&.name.==("punch.ops.console.operations")).operations
      console = {{ Punch::Operation.all_subclasses.select { |type| type.name.starts_with?("Punch::Ops::Console::") && type.annotation(Punch::Authorize) }.map(&.name.split("::").map(&.underscore).join(".")) }}.map(&.as(String))
      console.size.should be > 30
      (console.sort - listed).should be_empty
      Punch::Roles.used?.should be_true # ConsoleSpec::Operator; Punch's own role alone would not count
    end

    it "is open to signed-in users in development only, by default" do
      AuthSchema.with_spec_db do
        actor = ConsoleSpec::Anyone.new
        Punch::Spec.db.read do |db|
          Console::Development.check(actor, db).should eq(Punch::Policy::Decision::NotFound)
          Punch::Ops.development = true
          begin
            Console::Development.check(actor, db, error_id: 1_i64).should eq(Punch::Policy::Decision::Allow)
          ensure
            Punch::Ops.development = false
          end
        end
      end
    end

    it "is routed below /_punch and left out of the API" do
      routes = Punch::Routing.routes.select(&.operation.starts_with?("Punch::Ops::Console::"))
      routes.map(&.template).uniq!.sort!.should eq([
        "/_punch", "/_punch/bans", "/_punch/bans/lift", "/_punch/cache", "/_punch/cache/:store/clear", "/_punch/database", "/_punch/errors", "/_punch/errors/:error_id", "/_punch/errors/:error_id/reopen",
        "/_punch/errors/:error_id/resolve", "/_punch/events", "/_punch/jobs", "/_punch/jobs/:job_id", "/_punch/jobs/:job_id/discard",
        "/_punch/jobs/:job_id/retry", "/_punch/jobs/retry_failed", "/_punch/keys", "/_punch/mail", "/_punch/mail/:mail_id",
        "/_punch/mail/:mail_id/html", "/_punch/performance", "/_punch/performance/series", "/_punch/queues/:queue/pause",
        "/_punch/queues/:queue/resume", "/_punch/records/:record_id", "/_punch/recovery", "/_punch/recovery/confirm",
        "/_punch/webhooks", "/_punch/webhooks/:invocation_id", "/_punch/webhooks/:invocation_id/replay",
        "/_punch/webhooks/:invocation_id/retry",
      ])
      routes.all?(&.unlisted).should be_true
      routes.map(&.policy).uniq!.should eq(["ConsoleSpec::Operators"])
    end
  end

  describe "errors" do
    it "lists open errors and shows one with its backtrace and the request's wide event" do
      AuthSchema.with_spec_db do
        group = ConsoleSpec.error
        client = ConsoleSpec.operator
        list = client.visit(Console::ErrorsPage.href)
        list.should have_element("table.errors a", text: "IndexError")
        list.should have_element("table.errors code", text: "POST /console_spec/explode")
        detail = client.visit(Console::ErrorPage.href(error_id: group.id))
        detail.should have_element("h1", text: "IndexError")
        # Frame names of code that macros generate are not reliable; the
        # backtrace is there.
        detail.should have_element("pre", text: /\.cr:\d+/)
        detail.should have_element("details.occurrence dt", text: "http.route")
        detail.should have_element("details.occurrence dd code", text: "/console_spec/explode")
        detail.should have_element("form button", text: "Resolve")
        client.visit(Console::ErrorPage.href(error_id: group.id + 100)).status.code.should eq(404)
      end
    end

    it "resolves and reopens from the page" do
      AuthSchema.with_spec_db do
        group = ConsoleSpec.error
        client = ConsoleSpec.operator
        client.submit(Console::ResolveError.action(error_id: group.id)).should redirect_to(Console::ErrorPage.href(error_id: group.id))
        ConsoleSpec.must(Punch::Spec.ops.error(group.id)).resolved?.should be_true
        client.visit(Console::ErrorsPage.href).should have_element("p", text: "No open errors.")
        client.visit(Console::ErrorsPage.href(resolved: true)).should have_element("table.errors a", text: "IndexError")
        client.visit(Console::ErrorPage.href(error_id: group.id)).should have_element("form button", text: "Reopen")
        client.submit(Console::ReopenError.action(error_id: group.id)).should redirect_to(Console::ErrorPage.href(error_id: group.id))
        ConsoleSpec.must(Punch::Spec.ops.error(group.id)).resolved?.should be_false
      end
    end

    it "answers programs as JSON, with the state as a problem" do
      AuthSchema.with_spec_db do
        group = ConsoleSpec.error
        client = ConsoleSpec.operator
        client.post(Console::ResolveError.path(error_id: group.id)).json.should eq(JSON.parse(%({"id": #{group.id}, "state": "resolved"})))
        conflict = client.post(Console::ResolveError.path(error_id: group.id))
        conflict.status.code.should eq(409)
        conflict.json["code"].should eq("wrong_state")
        client.post(Console::ReopenError.path(error_id: 999_i64)).status.code.should eq(404)
      end
    end
  end

  describe "jobs" do
    it "shows failed jobs grouped, retries them all, and shows a job with its runs" do
      AuthSchema.with_spec_db do
        Punch::Spec.ops
        first = ConsoleSpec.failed_job("ada@example.org")
        ConsoleSpec.failed_job("grace@example.org")
        client = ConsoleSpec.operator
        jobs = client.visit(Console::JobsPage.href)
        jobs.should have_element("table.failed td", text: "2")
        jobs.should have_element("table.failed td", text: /mailbox full for grace/)
        jobs.should have_element("table.queues th", text: "mail")
        jobs.should have_element("table.recurring td", text: "Punch::Ops::Purge")
        job = client.visit(Console::JobPage.href(job_id: first))
        job.should have_element("h1", text: "Job #{first}: ConsoleSpec::Deliver")
        job.should have_element("pre", text: /ada@example\.org/)
        job.should have_element("table.runs td", text: "failed")
        client.submit(Console::RetryFailed.action, {job_type: "ConsoleSpec::Deliver"}).should redirect_to(Console::JobsPage.href)
        Punch::Spec.queue.list(state: "ready").size.should eq(2)
      end
    end

    it "retries and discards one job, and refuses what does not apply" do
      AuthSchema.with_spec_db do
        id = ConsoleSpec.failed_job
        client = ConsoleSpec.operator
        client.submit(Console::RetryJob.action(job_id: id)).should redirect_to(Console::JobPage.href(job_id: id))
        ConsoleSpec.must(Punch::Spec.queue.find(id)).state.should eq("ready")
        client.post(Console::RetryJob.path(job_id: id)).json["code"].should eq("wrong_state")
        client.submit(Console::DiscardJob.action(job_id: id)).should redirect_to(Console::JobPage.href(job_id: id))
        ConsoleSpec.must(Punch::Spec.queue.find(id)).state.should eq("discarded")
        client.post(Console::DiscardJob.path(job_id: 999_i64)).status.code.should eq(404)
      end
    end

    it "pauses and resumes a queue" do
      AuthSchema.with_spec_db do
        Punch::Spec.queue.enqueue(ConsoleSpec::Deliver.new("ada@example.org"))
        client = ConsoleSpec.operator
        client.submit(Console::PauseQueue.action(queue: Console::QueueName.parse("mail").as(Console::QueueName))).should redirect_to(Console::JobsPage.href)
        Punch::Spec.queue.paused.should eq(["mail"])
        client.visit(Console::JobsPage.href).should have_element("form button", text: "Resume mail")
        client.post("/_punch/queues/Mail/resume").status.code.should eq(404) # not a queue name
        client.submit(Console::ResumeQueue.action(queue: Console::QueueName.parse("mail").as(Console::QueueName))).should redirect_to(Console::JobsPage.href)
        Punch::Spec.queue.paused.should be_empty
      end
    end
  end

  describe "mail" do
    it "lists captured mail and shows one with both parts" do
      AuthSchema.with_spec_db do
        Punch::Spec.credentials(ConsoleSpec::Credentials, "mail:\n  delivery: capture\n  from: billing@example.org\n")
        Punch::Mailer.deliver_with(Punch::Spec::MAILS, ConsoleSpec::Hello.new, Punch::I18n.default, "job-1")
        mail = Punch::Spec.mails.last
        client = ConsoleSpec.operator
        client.visit(Console::MailsPage.href).should have_element("table.mails a", text: "Hello <Ada>")
        detail = client.visit(Console::MailPage.href(mail_id: mail.id))
        detail.should have_element("h1", text: "Hello <Ada>")
        detail.should have_element("pre", text: "Dear Ada <script>,")
        detail.should have_element("dd code", text: "job-1")
        html = client.visit(Console::MailHTMLPage.href(mail_id: mail.id))
        html.status.code.should eq(200)
        html.body.should contain("<p>Dear Ada &lt;script&gt;,</p>")
        client.visit(Console::MailPage.href(mail_id: 0_i64)).status.code.should eq(404)
        Punch::Spec.client.sign_in(2).visit(Console::MailsPage.href).status.code.should eq(404)
      end
    end
  end

  describe "cache" do
    it "shows each store's counters and what cache.db holds, and clears a store" do
      AuthSchema.with_spec_db do
        ConsoleSpec::TOTALS.fetch("a") { 1 }
        ConsoleSpec::TOTALS.fetch("a") { 2 }
        durable = Punch::Caches.durable || fail "cache.db is not attached"
        durable.put("console_totals", "0123456789abcdef", %("b"), "1", Time.utc + 1.minute, Time.utc)
        durable.put("console_gone", "0123456789abcdef", %("b"), "1", Time.utc + 1.minute, Time.utc)
        client = ConsoleSpec.operator
        page = client.visit(Console::CachePage.href)
        page.should have_element("nav a", text: "Cache")
        page.should have_element("table.stores th", text: "console_totals")
        page.should have_element("table.stores td", text: "50.0 %")
        page.should have_element("table.usage td", text: /\(earlier shape\)/)
        page.should have_element("table.usage th", text: "console_gone")

        name = Console::StoreName.parse("console_totals").as(Console::StoreName)
        client.submit(Console::ClearCache.action(store: name)).should redirect_to(Console::CachePage.href)
        ConsoleSpec::TOTALS.cached?("a").should be_false
        durable.usage(Time.utc).map(&.store).should_not contain("console_totals")
        # A store this process never used is cleared in the file.
        gone = Console::StoreName.parse("console_gone").as(Console::StoreName)
        client.submit(Console::ClearCache.action(store: gone)).should redirect_to(Console::CachePage.href)
        durable.usage(Time.utc).map(&.store).should_not contain("console_gone")
        client.post("/_punch/cache/Bad/clear").status.code.should eq(404)
        Punch::Spec.client.sign_in(2).visit(Console::CachePage.href).status.code.should eq(404)
      end
    end
  end

  describe "bans" do
    it "lists the addresses banned for probing and lifts a ban" do
      AuthSchema.with_spec_db do
        client = ConsoleSpec.operator
        client.visit(Console::BansPage.href).should have_element("p", text: /No server runs in this process/)
        guard = Punch::HTTP::Probes::Guard.new(Punch::HTTP::Probes::Settings.new, Punch::HTTP::Probes::Patterns.default, Punch::HTTP::TrustedProxies.none)
        Punch::HTTP::Probes.attach(guard)
        begin
          2.times { guard.check(HTTP::Request.new("GET", "/wp-login.php"), "203.0.113.7") }
          page = client.visit(Console::BansPage.href)
          page.should have_element("nav a", text: "Bans")
          page.should have_element("table.bans th", text: "203.0.113.7")
          page.should have_element("table.bans code", text: "/wp-login.php")
          page.should have_element("p", text: /2 requests for paths only scanners ask for/)
          address = Console::BannedAddress.parse("203.0.113.7").as(Console::BannedAddress)
          client.submit(Console::LiftBan.action, {address: address}).should redirect_to(Console::BansPage.href)
          guard.check(HTTP::Request.new("GET", "/invoices"), "203.0.113.7").should be_nil
          client.submit(Console::LiftBan.action, {address: address}).status.code.should eq(404)
          client.post(Console::LiftBan.path, json: {address: "example.org"}).status.code.should eq(422)
          Punch::Spec.client.sign_in(2).visit(Console::BansPage.href).status.code.should eq(404)
        ensure
          Punch::HTTP::Probes.attach(nil)
        end
      end
    end
  end

  describe "performance" do
    it "shows requests and named queries with percentiles, one name over time, and the slowest requests" do
      AuthSchema.with_spec_db do
        Punch::Spec.ops
        previous = Punch::Ops.slow
        Punch::Ops.slow = 0.milliseconds
        begin
          2.times { Punch::Spec.client.get(ConsoleSpec::Total.path).status.code.should eq(200) }
        ensure
          Punch::Ops.slow = previous
        end
        client = ConsoleSpec.operator
        page = client.visit(Console::PerformancePage.href)
        page.should have_element("table.stats th a", text: "GET /console_spec/total")
        page.should have_element("table.slowest a", text: "GET /console_spec/total")
        queries = client.visit(Console::PerformancePage.href(kind: Punch::Ops::StatsKind::Query, window: Punch::Ops::Window::Hour))
        queries.should have_element("table.stats th a", text: "ConsoleSpec.users")
        queries.should have_element("nav.tabs strong", text: "last hour")
        series = client.visit(Console::SeriesPage.href(kind: Punch::Ops::StatsKind::Query, name: "ConsoleSpec.users"))
        series.should have_element("h1", text: "ConsoleSpec.users")
        series.should have_element("table.series td", text: "2")
        record = Punch::Spec.ops.slowest(since: Time.utc - 1.hour).first
        client.visit(Console::RecordPage.href(record_id: record.id)).should have_element("dl.event dt", text: "http.route")
        client.visit(Console::RecordPage.href(record_id: record.id + 1000)).status.code.should eq(404)
        client.visit(Console::IndexPage.href).should have_element("section dt", text: "Last hour")
      end
    end
  end

  describe "events" do
    it "shows each event type with its publishers, subscribers, and commits, and the outbox" do
      AuthSchema.with_spec_db(ConsoleSpec::WEBHOOKS) do
        Punch::Spec.ops
        Punch::Spec.client.post(ConsoleSpec::Note.path, json: {tag: "a"}).status.code.should eq(204)
        page = ConsoleSpec.operator.visit(Console::EventsPage.href)
        page.should have_element("table.events th code", text: "ConsoleSpec::Noted")
        page.should have_element("table.events td code", text: "ConsoleSpec::Note")
        page.should have_element("table.events td", text: /ConsoleSpec::Listener \(after commit\)/)
        page.should have_element("table.latest code", text: "ConsoleSpec::Noted")
        page.should have_element("dl.summary dt", text: "Waiting to be handed over")
      end
    end

    it "says when the primary has no outbox" do
      AuthSchema.with_spec_db do
        ConsoleSpec.operator.visit(Console::EventsPage.href).should have_element("p", text: /has no outbox/)
      end
    end
  end

  describe "database" do
    it "reads each file's signals from the metrics" do
      Punch::Spec.database(file: true) do |db|
        registry = Punch::Metrics::Registry.new
        db.observe(registry)
        db.write(&.exec("CREATE TABLE t (x INTEGER) STRICT"))
        file = Console::DatabasePage.files(registry.collect).find!(&.name.==(db.name))
        ConsoleSpec.must(file.size).should be > 0
        file.pending.should eq(0)
        file.lag.should be_nil
      end
    end

    it "shows the files, the backup, and every metric" do
      AuthSchema.with_spec_db do
        page = ConsoleSpec.operator.visit(Console::DatabasePage.href)
        page.should have_element("h2", text: "Files")
        page.should have_element("p", text: /no storage directory/)
      end
    end

    it "shows a restore waiting for confirmation and confirms it" do
      AuthSchema.with_spec_db do
        storage = File.tempname("console-recovery")
        Dir.mkdir_p(storage)
        id = ConsoleSpec.must(Punch::Spec.queue.enqueue(ConsoleSpec::Tick.new))
        Punch::Spec.perform_jobs
        done = ConsoleSpec.must(Punch::Spec.queue.find(id))
        rerun = Punch::Backup::Reconciliation::Job.new(id, done.queue, done.type, "done", done.unique_key, done.enqueued_at, done.finished_at)
        plan = Punch::Backup::Restorer::Plan.new("primary", "0000000000000005", Time.utc - 1.minute, 1, 4096_i64)
        report = Punch::Backup::Recovery::Report.new(restored_at: Time.utc, requested: nil, aligned_at: nil, files: [plan],
          replaced: nil, reconciliation: Punch::Backup::Reconciliation.new(rerun: [rerun]))
        report.save(File.join(storage, Punch::Backup::Recovery::FILE))
        Punch::Backup.storage = storage
        begin
          client = ConsoleSpec.operator
          client.visit(Console::IndexPage.href).should have_element("p strong", text: "Recovery mode:")
          page = client.visit(Console::RecoveryPage.href)
          page.should have_element("h3", text: "Run again (their writes may be gone): 1")
          page.should have_element("table.restored th", text: "primary.db")
          client.submit(Console::ConfirmRecovery.action).should redirect_to(Console::RecoveryPage.href)
          ConsoleSpec.must(Punch::Spec.queue.find(id)).state.should eq("ready")
          Punch::Backup::Recovery.pending?(storage).should be_false
          client.visit(Console::RecoveryPage.href).should have_element("p", text: /The last recovery/)
          client.visit(Console::DatabasePage.href).should have_element("dd a", text: /confirmed/)
          client.post(Console::ConfirmRecovery.path).status.code.should eq(404)
        ensure
          Punch::Backup.storage = nil
          FileUtils.rm_rf(storage)
        end
      end
    end
  end

  describe "keys and credentials" do
    it "shows each key's age, role, and old-key uses, and where each credential came from" do
      AuthSchema.with_spec_db do
        Punch::Spec.credentials(ConsoleSpec::Credentials, "mail:\n  delivery: capture\n  from: billing@example.org\n")
        old = Punch::KeyRing::Key.new(1_u32, Bytes.new(32, 1_u8), Time.utc(2026, 1, 1))
        new = Punch::KeyRing::Key.new(2_u32, Bytes.new(32, 2_u8), Time.utc(2026, 9, 1))
        signed = Punch::KeyRing.new([old]).signer("console").sign_text("hello")
        previous = Punch::KeyRing.current?
        ring = Punch::KeyRing.new([new, old])
        Punch::KeyRing.current = ring
        begin
          ring.signer("console").verify_text(signed).should eq("hello")
          page = ConsoleSpec.operator.visit(Console::KeysPage.href)
          page.should have_element("table.keys td", text: "signs")
          page.should have_element("table.keys td", text: "verifies")
          page.should have_element("table.keys td", text: "1")
          page.should have_element("table.keys td", text: "2026-01-01")
          page.should have_element("table.credentials code", text: "mail.delivery")
          page.should_not have_element("td", text: /\x01/)
        ensure
          Punch::KeyRing.current = previous if previous
        end
      end
    end
  end

  describe "webhooks" do
    it "lists invocations by provider and state, and shows one with its stored request" do
      AuthSchema.with_spec_db(ConsoleSpec::WEBHOOKS) do
        failed = ConsoleSpec.invocation("failed")
        ConsoleSpec.invocation("processed")
        client = ConsoleSpec.operator
        page = client.visit(Console::WebhooksPage.href)
        page.should have_element("table.providers th a", text: "console")
        page.should have_element("table.invocations a", text: failed.to_s)
        provider = Console::ProviderName.parse("console").as(Console::ProviderName)
        only_failed = client.visit(Console::WebhooksPage.href(provider: provider, state: Console::InvocationState::Failed))
        only_failed.should have_element("h2", text: "Latest invocations of console, failed")
        only_failed.should have_element("table.invocations td", text: "upstream said no")
        detail = client.visit(Console::WebhookPage.href(invocation_id: failed))
        detail.should have_element("dl.headers dt", text: "webhook-id")
        detail.should have_element("pre", text: %({"n": 1}))
        detail.should have_element("form button", text: "Retry")
        client.visit(Console::WebhookPage.href(invocation_id: failed + 100)).status.code.should eq(404)
      end
    end

    it "retries a failed invocation and replays a processed one through the outbox" do
      AuthSchema.with_spec_db(ConsoleSpec::WEBHOOKS) do
        failed = ConsoleSpec.invocation("failed")
        processed = ConsoleSpec.invocation("processed")
        rejected = ConsoleSpec.invocation("rejected")
        client = ConsoleSpec.operator
        before = ConsoleSpec.pings
        client.post(Console::RetryWebhook.path(invocation_id: failed)).json.should eq(JSON.parse(%({"id": #{failed}, "state": "verified"})))
        client.submit(Console::ReplayWebhook.action(invocation_id: processed)).should redirect_to(Console::WebhookPage.href(invocation_id: processed))
        Punch::Spec.perform_jobs
        ConsoleSpec.pings.should eq(before + 2)
        ConsoleSpec.state(failed).should eq("processed")
        ConsoleSpec.state(processed).should eq("processed")
        # Its signature is checked again before anything else.
        client.post(Console::RetryWebhook.path(invocation_id: rejected)).json["state"].should eq("received")
        conflict = client.post(Console::ReplayWebhook.path(invocation_id: ConsoleSpec.invocation("failed")))
        conflict.status.code.should eq(409)
        conflict.json["state"].should eq("failed")
        client.post(Console::RetryWebhook.path(invocation_id: 999_i64)).status.code.should eq(404)
      end
    end
  end

  describe "for programs and agents" do
    it "answers each report as JSON on the page's path" do
      AuthSchema.with_spec_db do
        group = ConsoleSpec.error
        job = ConsoleSpec.failed_job
        client = ConsoleSpec.operator
        client.get(Console::IndexPage.href.to_s).json["errors"]["open_errors"].as_i.should be > 0
        client.get(Console::ErrorsPage.href.to_s).json["errors"].as_a.map(&.["id"].as_i64).should contain(group.id)
        client.get(Console::ErrorsPage.href(resolved: true).to_s).json["errors"].as_a.should be_empty
        detail = client.get(Console::ErrorPage.href(error_id: group.id).to_s).json
        detail["exception"].should eq("IndexError")
        detail["latest"].as_a.size.should eq(1)
        missing = client.get(Console::ErrorPage.href(error_id: group.id + 100).to_s)
        missing.status.code.should eq(404)
        missing.json["code"].should eq("not_found")
        client.get(Console::JobsPage.href.to_s).json["failed"][0]["type"].should eq("ConsoleSpec::Deliver")
        client.get(Console::JobPage.href(job_id: job).to_s).json["state"].should eq("failed")
        performance = client.get(Console::PerformancePage.href(window: Punch::Ops::Window::Hour).to_s).json
        performance["stats"].as_a.map(&.["name"]).should contain("POST /console_spec/explode")
        failed = performance["slowest"].as_a.find! { |slow| slow["name"] == "POST /console_spec/explode" }
        record = client.get(Console::RecordPage.href(record_id: failed["record_id"].as_i64).to_s).json
        record["fields"]["http.response.status_code"].should eq(500)
        # A browser still gets the page.
        client.visit(Console::ErrorsPage.href).should have_element("table.errors a", text: "IndexError")
        Punch::Spec.client.sign_in(2).get(Console::ErrorsPage.href.to_s).status.code.should eq(404)
      end
    end

    it "says which file is not open" do
      AuthSchema.with_spec_db do
        answer = ConsoleSpec.operator.get(Console::ErrorsPage.href.to_s)
        answer.status.code.should eq(404)
        {answer.json["code"], answer.json["database"]}.should eq({"unavailable", "ops.db"})
        ConsoleSpec.operator.get(Console::IndexPage.href.to_s).json["errors"].raw.should be_nil
      end
    end

    it "is read by agents as markdown, its buttons as actions" do
      AuthSchema.with_spec_db do
        group = ConsoleSpec.error
        ConsoleSpec.failed_job
        agent = Punch::Spec.bearer(Punch::Spec.api_token(1))
        client = Punch::Spec.client
        list = client.read(Console::ErrorsPage.href, headers: agent)
        list.status.code.should eq(200)
        list.headers["Content-Type"].should start_with("text/markdown")
        list.body.should contain("# Open errors")
        list.body.should contain("](#{Console::ErrorPage.href(error_id: group.id).markdown_url})")
        client.get("/_punch.md", headers: agent).body.should contain("# Ops")
        page = client.read(Console::ErrorPage.href(error_id: group.id), headers: agent)
        page.body.should contain("IndexError")
        page.should have_action("Resolve", operation: "punch.ops.console.resolve_error")
        client.act(page, "Resolve", headers: agent).status.code.should eq(303)
        ConsoleSpec.must(Punch::Spec.ops.error(group.id)).resolved?.should be_true
        jobs = client.read(Console::JobsPage.href, headers: agent)
        jobs.should have_action("Retry all 1")
        # Anyone else learns nothing, in markdown too.
        stranger = Punch::Spec.bearer(Punch::Spec.api_token(2))
        client.read(Console::ErrorsPage.href, headers: stranger).status.code.should eq(404)
      end
    end

    it "renders every page as markdown" do
      AuthSchema.with_spec_db(ConsoleSpec::WEBHOOKS) do
        group = ConsoleSpec.error
        job = ConsoleSpec.failed_job
        invocation = ConsoleSpec.invocation("failed")
        record = ConsoleSpec.must(Punch::Spec.ops.records(failed: true).first?)
        agent = Punch::Spec.bearer(Punch::Spec.api_token(1))
        client = Punch::Spec.client
        hrefs = [Console::IndexPage.href, Console::ErrorsPage.href, Console::ErrorPage.href(error_id: group.id),
                 Console::JobsPage.href, Console::JobPage.href(job_id: job), Console::PerformancePage.href,
                 Console::SeriesPage.href(kind: Punch::Ops::StatsKind::Request, name: "POST /console_spec/explode"),
                 Console::RecordPage.href(record_id: record.id), Console::EventsPage.href, Console::DatabasePage.href,
                 Console::RecoveryPage.href, Console::KeysPage.href, Console::WebhooksPage.href,
                 Console::WebhookPage.href(invocation_id: invocation), Console::MailsPage.href, Console::CachePage.href,
                 Console::BansPage.href]
        hrefs.each do |href|
          answer = client.get(href.markdown_url, headers: agent)
          {href.to_s, answer.status.code, answer.headers["Content-Type"]?}.should eq({href.to_s, 200, "text/markdown; charset=utf-8; variant=GFM"})
        end
      end
    end

    it "is what punch ops --url reads and acts on" do
      AuthSchema.with_spec_db do
        group = ConsoleSpec.error
        job = ConsoleSpec.failed_job
        ConsoleSpec.serving do |url|
          ENV["PUNCH_OPS_TOKEN"] = Punch::Spec.api_token(1)
          begin
            ConsoleSpec.cli("ops", "--url", url)[1]["errors"]["open_errors"].as_i.should be > 0
            ConsoleSpec.cli("ops:errors", "--url", url)[1]["errors"].as_a.map(&.["id"].as_i64).should contain(group.id)
            ConsoleSpec.cli("ops:error", group.id.to_s, "--url", url)[1]["exception"].should eq("IndexError")
            ConsoleSpec.cli("ops:resolve", group.id.to_s, "--url", url)[1].should eq(JSON.parse(%({"id": #{group.id}, "state": "resolved"})))
            code, refused = ConsoleSpec.cli("ops:resolve", group.id.to_s, "--url", url)
            {code, refused["error"]["code"]}.should eq({1, "wrong_state"})
            refused["error"]["message"].as_s.should contain("it is resolved")
            ConsoleSpec.cli("ops:errors", "--resolved", "--url", url)[1]["errors"].as_a.map(&.["id"].as_i64).should eq([group.id])
            ConsoleSpec.cli("ops:reopen", group.id.to_s, "--url", url)[1]["state"].should eq("open")
            ConsoleSpec.cli("ops:jobs", "--url", url)[1]["failed"][0]["type"].should eq("ConsoleSpec::Deliver")
            ConsoleSpec.cli("ops:job", job.to_s, "--url", url)[1]["state"].should eq("failed")
            ConsoleSpec.cli("ops:retry", job.to_s, "--url", url)[1]["state"].should eq("ready")
            ConsoleSpec.cli("ops:discard", job.to_s, "--url", url)[1]["state"].should eq("discarded")
            ConsoleSpec.cli("ops:retry", "--type", "ConsoleSpec::Deliver", "--url", url)[1]["retried"].should eq(0)
            ConsoleSpec.cli("ops:performance", "--window", "hour", "--url", url)[1]["stats"].as_a.map(&.["name"]).should contain("POST /console_spec/explode")
            slow = ConsoleSpec.cli("ops:slow", "--url", url)[1]["slowest"].as_a.find! { |request| request["name"] == "POST /console_spec/explode" }
            record = ConsoleSpec.cli("ops:record", slow["record_id"].to_s, "--url", url)[1]
            record["fields"]["http.route"].should eq("/console_spec/explode")
            ConsoleSpec.cli("ops:job", "999999", "--url", url)[1]["error"]["code"].should eq("not_found")
            # Text, as on the box.
            stdout = IO::Memory.new
            Punch::CLI.run(["ops:errors", "--url", url], stdout, IO::Memory.new).should eq(0)
            stdout.to_s.should contain("IndexError in POST /console_spec/explode")
            ENV["PUNCH_OPS_TOKEN"] = Punch::Spec.api_token(2)
            ConsoleSpec.cli("ops:errors", "--url", url)[1]["error"]["code"].should eq("not_found")
            ENV["PUNCH_OPS_TOKEN"] = "#{Punch::Spec.api_token(1)}x"
            ConsoleSpec.cli("ops:errors", "--url", url)[1]["error"]["code"].should eq("unauthenticated")
          ensure
            ENV.delete("PUNCH_OPS_TOKEN")
          end
        end
      end
    end

    it "lives at the paths punch ops --url uses" do
      Punch::CLI::Commands::OpsPaths::OVERVIEW.should eq(Console::ShowOverview.path)
      Punch::CLI::Commands::OpsPaths::ERRORS.should eq(Console::ListErrors.path)
      Punch::CLI::Commands::OpsPaths.error(5).should eq(Console::ShowError.path(error_id: 5_i64))
      Punch::CLI::Commands::OpsPaths.error(5, "resolve").should eq(Console::ResolveError.path(error_id: 5_i64))
      Punch::CLI::Commands::OpsPaths.error(5, "reopen").should eq(Console::ReopenError.path(error_id: 5_i64))
      Punch::CLI::Commands::OpsPaths::JOBS.should eq(Console::ShowJobs.path)
      Punch::CLI::Commands::OpsPaths.job(5).should eq(Console::ShowJob.path(job_id: 5_i64))
      Punch::CLI::Commands::OpsPaths.job(5, "retry").should eq(Console::RetryJob.path(job_id: 5_i64))
      Punch::CLI::Commands::OpsPaths.job(5, "discard").should eq(Console::DiscardJob.path(job_id: 5_i64))
      Punch::CLI::Commands::OpsPaths::RETRY_FAILED.should eq(Console::RetryFailed.path)
      Punch::CLI::Commands::OpsPaths::PERFORMANCE.should eq(Console::ShowPerformance.path)
      Punch::CLI::Commands::OpsPaths.record(5).should eq(Console::ShowRecord.path(record_id: 5_i64))
    end
  end

  it "says so when ops.db is not open" do
    AuthSchema.with_spec_db do
      client = ConsoleSpec.operator
      client.visit(Console::IndexPage.href).should have_element("p", text: /ops\.db is not open/)
      client.visit(Console::ErrorsPage.href).should have_element("p", text: /ops\.db is not open/)
    end
  end
end
