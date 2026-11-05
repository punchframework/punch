require "../../punch"

# The ops console: errors, jobs, performance, events, the databases and
# backup, keys and credentials, inbound webhooks, captured mail, the cache,
# and banned addresses, at `/_punch`, built from Punch's own pages,
# Commands, and components. An app mounts it by requiring this file and
# naming its actor and the policy of who may use it (docs/ops.md):
#
# ```
# require "punch/ops/console"
#
# Punch::Ops::Console.mount Invoicing::Actor, Punch::Ops::Console::ByRole
# ```
#
# `ByRole` lets in whoever holds a global role that includes
# `Punch::Ops::Console::Operations` (`console/access.cr`). Without a
# policy, `Punch::Ops::Console::Development` lets any signed-in
# user in when the process runs with `PUNCH_ENV=development`, and answers
# 404 everywhere else. The console's routes are left out of
# `openapi.json` (`@[Punch::Unlisted]`).
module Punch::Ops::Console
  # Names the app's actor and the console's policy. Use once, at the top
  # level of the app.
  macro mount(viewer, access = ::Punch::Ops::Console::Development)
    # The app's actor, as the console's operations take it.
    alias ::Punch::Ops::Console::Viewer = {{ viewer.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
    # Who may use the ops console.
    alias ::Punch::Ops::Console::Access = {{ access.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
  end

  macro finished
    {% unless @type.has_constant?("Viewer") && @type.has_constant?("Access") %}
      {% raise "punch/ops/console is required, but not mounted. Name the app's actor and the console's policy once: Punch::Ops::Console.mount Invoicing::Actor, Punch::Ops::Console::ByRole (lib/punch/docs/ops.md)." %}
    {% end %}
  end

  # The default policy: any signed-in user in development, 404 elsewhere,
  # so a production app shows no console until it names who may use it.
  struct Development
    include Punch::Policy

    def self.check(actor : Punch::Auth::Actor, db : Punch::Reader | Punch::Writer, **params) : Punch::Policy::Decision
      Ops.development? ? allow : not_found
    end
  end

  # 404 for an error or job that does not exist, or when `ops.db` is off.
  @[Punch::Status(404)]
  struct NotFound
    include JSON::Serializable

    def initialize
    end
  end

  # 409: the error or job is not in a state the action applies to.
  @[Punch::Status(409)]
  struct WrongState
    include JSON::Serializable

    getter state : String

    def initialize(@state)
    end
  end

  # A cache store's name in a path.
  struct StoreName
    include Punch::Primitive(String)

    def self.parse(raw : String) : self | Punch::Invalid
      raw.matches?(/\A[a-z][a-z0-9_]{0,62}\z/) ? new(raw) : Punch::Invalid.new("invalid_store")
    end
  end

  # A queue's name in a path.
  struct QueueName
    include Punch::Primitive(String)

    def self.parse(raw : String) : self | Punch::Invalid
      raw.matches?(/\A[a-z][a-z0-9_]{0,62}\z/) ? new(raw) : Punch::Invalid.new("invalid_queue")
    end
  end

  # The time as the console shows it, in UTC.
  def self.time(time : Time?) : String
    time ? time.to_utc.to_s("%Y-%m-%d %H:%M:%S") : "–"
  end

  # The first line of a stored error.
  def self.first_line(text : String?) : String
    text.try(&.lines.first?) || ""
  end

  # The console's stylesheet, served beside the app's assets.
  STYLESHEET = "punch/ops.css"
  ::Punch::Assets.add(STYLESHEET, {{ read_file("#{__DIR__}/console/console.css") }})

  # The frame of every console page: navigation and the content.
  struct Layout
    include Punch::Component

    def initialize(@title : String)
    end

    def view(v : Punch::View, &) : Nil
      v.document("#{@title} · Punch ops", stylesheets: {Punch::Asset::Stylesheet.new(STYLESHEET)}) do
        v.chrome do |chrome|
          chrome.nav(aria: {label: "Ops"}) do
            chrome.a "Overview", href: IndexPage.href
            chrome.text " "
            chrome.a "Errors", href: ErrorsPage.href
            chrome.text " "
            chrome.a "Jobs", href: JobsPage.href
            chrome.text " "
            chrome.a "Performance", href: PerformancePage.href
            chrome.text " "
            chrome.a "Events", href: EventsPage.href
            chrome.text " "
            chrome.a "Database", href: DatabasePage.href
            chrome.text " "
            chrome.a "Keys", href: KeysPage.href
            chrome.text " "
            chrome.a "Webhooks", href: WebhooksPage.href
            chrome.text " "
            chrome.a "Mail", href: MailsPage.href
            chrome.text " "
            chrome.a "Cache", href: CachePage.href
            chrome.text " "
            chrome.a "Bans", href: BansPage.href
          end
        end
        v.main { yield }
      end
    end
  end

  # What a page says when `ops.db` or `queue.db` is not open.
  struct Off
    include Punch::Component

    def initialize(@what : String)
    end

    def view(v : Punch::View) : Nil
      v.p "#{@what} is not open in this process (PUNCH_OPS=off, or a binary that does not serve)."
    end
  end

  # ---- Overview -----------------------------------------------------------

  struct Overview
    include Punch::Component

    def initialize(@summary : Summary?, @counts : Array(Job::Queue::Count)?, @processes : Array(Job::Queue::Process)?,
                   @requests : Array(Stats)? = nil, @recovering : Bool = false)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Overview") do
        v.h1 "Ops"
        if @recovering
          v.p do
            v.strong "Recovery mode: "
            v.text "the files were restored and background work waits for the reconciliation to be confirmed. "
            v.a "Review and confirm", href: RecoveryPage.href
          end
        end
        v.section do
          v.h2 { v.a "Errors", href: ErrorsPage.href }
          if summary = @summary
            v.dl(class: "summary") do
              v.dt "Open errors"
              v.dd summary.open_errors.to_s
              v.dt "Occurrences, last 24 h"
              v.dd summary.occurrences_24h.to_s
              v.dt "Failed job runs, last 24 h"
              v.dd "#{summary.failed_runs_24h} of #{summary.runs_24h}"
            end
          else
            v.render Off.new("ops.db")
          end
        end
        v.section do
          v.h2 { v.a "Jobs", href: JobsPage.href }
          if (counts = @counts) && (processes = @processes)
            totals = counts.group_by(&.state).transform_values(&.sum(&.jobs))
            v.dl(class: "summary") do
              %w[ready scheduled running blocked failed incompatible].each do |state|
                v.dt state
                v.dd((totals[state]? || 0).to_s)
              end
              v.dt "Processes"
              v.dd processes.size.to_s
            end
          else
            v.render Off.new("queue.db")
          end
        end
        @requests.try { |requests| requests(v, requests) }
      end
    end

    private def requests(v : Punch::View, requests : Array(Stats)) : Nil
      v.section do
        v.h2 { v.a "Requests", href: PerformancePage.href(kind: StatsKind::Request, window: Window::Hour) }
        runs = requests.sum(&.count)
        v.dl(class: "summary") do
          v.dt "Last hour"
          v.dd runs.to_s
          v.dt "Failed (5xx)"
          v.dd requests.sum(&.failed).to_s
          v.dt "Average"
          v.dd Console.ms(runs > 0 ? requests.sum(&.total_ms) / runs : nil)
        end
      end
    end
  end

  # `GET /_punch`: open errors and the state of the queue at a glance.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch")]
  struct IndexPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = Overview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      queue = Job::Queue.current?
      store = Ops.current?
      requests = store.try(&.stats("request", since: Time.utc - 1.hour))
      recovering = Backup.storage.try { |storage| Backup::Recovery.pending?(storage) } || false
      Overview.new(store.try(&.summary), queue.try(&.counts), queue.try(&.processes), requests, recovering)
    end
  end

  # ---- Errors -------------------------------------------------------------

  struct ErrorList
    include Punch::Component

    def initialize(@groups : Array(ErrorGroup)?, @resolved : Bool)
    end

    def view(v : Punch::View) : Nil
      title = @resolved ? "Resolved errors" : "Open errors"
      v.render Layout.new(title) do
        v.h1 title
        v.p do
          @resolved ? v.a("Open errors", href: ErrorsPage.href) : v.a("Resolved errors", href: ErrorsPage.href(resolved: true))
        end
        groups = @groups
        if groups.nil?
          v.render Off.new("ops.db")
        elsif groups.empty?
          v.p @resolved ? "No resolved errors." : "No open errors."
        else
          v.table(class: "errors") do
            v.thead { v.tr { ["Error", "Where", "Count", "Last seen", "First seen"].each { |label| v.th label, scope: "col" } } }
            v.tbody do
              groups.each do |group|
                v.tr do
                  v.td do
                    v.a group.exception, href: ErrorPage.href(error_id: group.id)
                    group.message.try { |message| v.br; v.small Console.first_line(message) }
                  end
                  v.td { v.code group.source }
                  v.td group.occurrences.to_s
                  v.td { v.time Console.time(group.last_seen), datetime: group.last_seen }
                  v.td { v.time Console.time(group.first_seen), datetime: group.first_seen }
                end
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/errors`: error groups, most recently seen first; open
  # ones, or resolved ones with `?resolved=true`.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/errors")]
  struct ErrorsPage < Punch::Page
    struct Input
      include Punch::Input

      getter? resolved : Bool = false
    end

    alias Output = ErrorList

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      ErrorList.new(Ops.current?.try(&.errors(resolved: input.resolved?, limit: 200)), input.resolved?)
    end
  end

  # One occurrence with the wide event it was raised in, when kept.
  record Seen, occurrence : Occurrence, record : StoredRecord?

  struct ErrorDetail
    include Punch::Component

    def initialize(@group : ErrorGroup, @seen : Array(Seen))
    end

    def view(v : Punch::View) : Nil
      group = @group
      v.render Layout.new(group.exception) do
        v.h1 group.exception
        v.dl(class: "facts") do
          v.dt "Where"
          v.dd { v.code group.source }
          v.dt "State"
          v.dd group.resolved? ? "resolved #{Console.time(group.resolved_at)}" : "open"
          v.dt "Occurrences"
          v.dd "#{group.occurrences}, first #{Console.time(group.first_seen)}, last #{Console.time(group.last_seen)}"
          v.dt "Fingerprint"
          v.dd { v.code group.fingerprint }
        end
        if group.resolved?
          v.form(ReopenError.action(error_id: group.id)) { |form| form.submit "Reopen" }
        else
          v.form(ResolveError.action(error_id: group.id)) { |form| form.submit "Resolve" }
        end
        group.message.try { |message| v.h2 "Message"; v.pre message }
        group.backtrace.try { |trace| v.h2 "Backtrace"; v.pre trace }
        v.h2 "Latest occurrences"
        @seen.each { |seen| occurrence(v, seen) }
      end
    end

    private def occurrence(v : Punch::View, seen : Seen) : Nil
      occurrence = seen.occurrence
      v.details(class: "occurrence") do
        v.summary do
          v.time Console.time(occurrence.at), datetime: occurrence.at
          occurrence.trace_id.try { |id| v.text " trace "; v.code id }
          occurrence.message.try { |message| v.text " "; v.text Console.first_line(message) }
        end
        if record = seen.record
          v.render Timing.new(record)
          v.dl(class: "event") do
            JSON.parse(record.fields).as_h.each do |key, value|
              v.dt key
              v.dd { v.code value.as_s? || value.to_json }
            end
          end
        else
          v.p "Its wide event is no longer kept."
        end
      end
    end
  end

  # `GET /_punch/errors/:error_id`: one error group with its backtrace and
  # the wide events of its latest occurrences.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/errors/:error_id")]
  @[Punch::Forms(ResolveError, ReopenError)]
  struct ErrorPage < Punch::Page
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter error_id : Int64
    end

    alias Output = ErrorDetail | NotFound

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current? || return NotFound.new
      group = store.error(input.error_id) || return NotFound.new
      seen = store.occurrences(group.id).map { |occurrence| Seen.new(occurrence, occurrence.record_id.try { |id| store.record(id) }) }
      ErrorDetail.new(group, seen)
    end
  end

  # What a Command on an error answers.
  struct ErrorState
    include JSON::Serializable

    getter id : Int64
    getter state : String

    def initialize(@id, @state)
    end
  end

  # `POST /_punch/errors/:error_id/resolve`: marks an open error resolved.
  # It opens again when it recurs.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/errors/:error_id/resolve")]
  struct ResolveError < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter error_id : Int64
    end

    alias Output = ErrorState | NotFound | WrongState

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(ResolveError)) : Output
      store = Ops.current? || return NotFound.new
      return ErrorState.new(input.error_id, "resolved") if store.resolve(input.error_id)

      store.error(input.error_id) ? WrongState.new("resolved") : NotFound.new
    end
  end

  # `POST /_punch/errors/:error_id/reopen`: opens a resolved error again.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/errors/:error_id/reopen")]
  struct ReopenError < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter error_id : Int64
    end

    alias Output = ErrorState | NotFound | WrongState

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(ReopenError)) : Output
      store = Ops.current? || return NotFound.new
      return ErrorState.new(input.error_id, "open") if store.reopen(input.error_id)

      store.error(input.error_id) ? WrongState.new("open") : NotFound.new
    end
  end

  # ---- Jobs ---------------------------------------------------------------

  # What the jobs page shows.
  record JobsState, counts : Array(Job::Queue::Count), paused : Array(String), failed : Array(Job::Queue::FailedGroup),
    parked : Array(Job::Queue::Row), running : Array(Job::Queue::Row), scheduled : Array(Job::Queue::Row),
    tasks : Array(Job::Queue::Task), processes : Array(Job::Queue::Process), now : Time

  struct JobsOverview
    include Punch::Component

    def initialize(@state : JobsState?)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Jobs") do
        v.h1 "Jobs"
        if state = @state
          queues(v, state)
          failed(v, state)
          jobs(v, "Incompatible payloads", state.parked, state.now, "None parked.")
          jobs(v, "Running", state.running, state.now, "Nothing running.")
          jobs(v, "Scheduled", state.scheduled, state.now, "Nothing scheduled.")
          recurring(v, state)
          processes(v, state)
        else
          v.render Off.new("queue.db")
        end
      end
    end

    private def queues(v : Punch::View, state : JobsState) : Nil
      v.section do
        v.h2 "Queues"
        names = (state.counts.map(&.queue) + state.paused).uniq!.sort!
        if names.empty?
          v.p "No jobs yet."
          return
        end
        columns = %w[ready scheduled running blocked done discarded failed incompatible]
        v.table(class: "queues") do
          v.thead { v.tr { (["Queue"] + columns + [""]).each { |label| v.th label, scope: "col" } } }
          v.tbody do
            names.each do |name|
              v.tr do
                v.th name, scope: "row"
                columns.each do |column|
                  v.td((state.counts.find { |count| count.queue == name && count.state == column }.try(&.jobs) || 0).to_s)
                end
                v.td do
                  # Stored names were checked when the job was enqueued.
                  if queue = QueueName.parse(name).as?(QueueName)
                    if state.paused.includes?(name)
                      v.form(ResumeQueue.action(queue: queue)) { |form| form.submit "Resume #{name}" }
                    else
                      v.form(PauseQueue.action(queue: queue)) { |form| form.submit "Pause #{name}" }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def failed(v : Punch::View, state : JobsState) : Nil
      v.section do
        v.h2 "Failed"
        if state.failed.empty?
          v.p "No failed jobs."
          return
        end
        v.table(class: "failed") do
          v.thead { v.tr { ["Type", "Jobs", "Latest error", "Last failed", ""].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            state.failed.each do |group|
              v.tr do
                v.td { v.a group.type, href: JobPage.href(job_id: group.latest_id) }
                v.td group.count.to_s
                v.td Console.first_line(group.error)
                v.td Console.time(group.last_failed)
                v.td do
                  v.form(RetryFailed.action, values: {job_type: group.type}) do |form|
                    form.field :job_type, as: :hidden
                    form.submit "Retry all #{group.count}"
                  end
                end
              end
            end
          end
        end
      end
    end

    private def jobs(v : Punch::View, title : String, rows : Array(Job::Queue::Row), now : Time, empty : String) : Nil
      v.section do
        v.h2 title
        if rows.empty?
          v.p empty
          return
        end
        v.table do
          v.thead { v.tr { ["Job", "Type", "Queue", "Attempts", "Run at", "Error"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            rows.each do |row|
              v.tr do
                v.td { v.a row.id.to_s, href: JobPage.href(job_id: row.id) }
                v.td row.type
                v.td row.queue
                v.td "#{row.attempts}/#{row.max_attempts}"
                v.td Console.time(row.run_at)
                v.td Console.first_line(row.error)
              end
            end
          end
        end
      end
    end

    private def recurring(v : Punch::View, state : JobsState) : Nil
      v.section do
        v.h2 "Recurring"
        v.table(class: "recurring") do
          v.thead { v.tr { ["Type", "Schedule", "Next run"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            state.tasks.each do |task|
              v.tr do
                v.td task.type
                v.td { v.code task.schedule.to_s }
                v.td Console.time(task.schedule.next_after(state.now))
              end
            end
          end
        end
      end
    end

    private def processes(v : Punch::View, state : JobsState) : Nil
      v.section do
        v.h2 "Processes"
        if state.processes.empty?
          v.p "No process is running workers."
          return
        end
        v.table(class: "processes") do
          v.thead { v.tr { ["Process", "Kind", "Queues", "Started", "Last heartbeat"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            state.processes.each do |process|
              v.tr do
                v.td { v.code process.id }
                v.td process.kind
                v.td process.queues
                v.td Console.time(process.started_at)
                v.td Console.time(process.heartbeat_at)
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/jobs`: queues with counts and pausing, failed jobs grouped
  # by type, parked, running, and scheduled jobs, recurring jobs, and the
  # processes running workers.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/jobs")]
  @[Punch::Forms(RetryFailed, PauseQueue, ResumeQueue)]
  struct JobsPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = JobsOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      queue = Job::Queue.current? || return JobsOverview.new(nil)
      now = Time.utc
      JobsOverview.new(JobsState.new(queue.counts, queue.paused, queue.failed_groups, queue.list(state: "incompatible"),
        queue.list(state: "running"), queue.list(state: "scheduled", limit: 20).reverse!, Job::Queue.tasks, queue.processes, now))
    end
  end

  struct JobDetail
    include Punch::Component

    def initialize(@row : Job::Queue::Row, @runs : Array(StoredRecord)?, @now : Time)
    end

    def view(v : Punch::View) : Nil
      row = @row
      state = row.display_state(@now)
      v.render Layout.new("Job #{row.id}") do
        v.h1 "Job #{row.id}: #{row.type}"
        v.dl(class: "facts") do
          v.dt "State"
          v.dd state
          v.dt "Queue"
          v.dd "#{row.queue}, priority #{row.priority}"
          v.dt "Attempts"
          v.dd "#{row.attempts} of #{row.max_attempts}"
          v.dt "Payload version"
          v.dd row.version.to_s
          v.dt "Enqueued"
          v.dd Console.time(row.enqueued_at)
          v.dt "Run at"
          v.dd Console.time(row.run_at)
          v.dt "Finished"
          v.dd Console.time(row.finished_at)
          row.unique_key.try { |key| v.dt "Unique key"; v.dd { v.code key } }
          row.concurrency_key.try { |key| v.dt "Concurrency key"; v.dd { v.code key } }
          row.claimed_by.try { |process| v.dt "Claimed by"; v.dd { v.code process } }
        end
        if state.in?("failed", "discarded", "incompatible")
          v.form(RetryJob.action(job_id: row.id)) { |form| form.submit "Retry" }
        end
        if state.in?("ready", "scheduled", "blocked", "failed", "incompatible")
          v.form(DiscardJob.action(job_id: row.id)) { |form| form.submit "Discard" }
        end
        v.h2 "Payload"
        v.pre row.payload
        row.error.try { |error| v.h2 "Error"; v.pre error }
        runs(v)
      end
    end

    private def runs(v : Punch::View) : Nil
      v.h2 "Runs"
      runs = @runs
      if runs.nil?
        v.render Off.new("ops.db")
      elsif runs.empty?
        v.p "No run recorded (sampled, or past retention)."
      else
        v.table(class: "runs") do
          v.thead { v.tr { ["Started", "Duration", "Outcome", "Trace"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            runs.each do |run|
              fields = JSON.parse(run.fields)
              v.tr do
                v.td Console.time(run.at)
                v.td run.duration_ms.try { |duration| "#{duration} ms" } || "–"
                v.td fields["punch.job.outcome"]?.try(&.as_s?) || (run.failed ? "failed" : "–")
                v.td { run.trace_id.try { |id| v.code id } }
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/jobs/:job_id`: one job with its payload, last error, and
  # its runs from `ops.db`.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/jobs/:job_id")]
  @[Punch::Forms(RetryJob, DiscardJob)]
  struct JobPage < Punch::Page
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter job_id : Int64
    end

    alias Output = JobDetail | NotFound

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      queue = Job::Queue.current? || return NotFound.new
      row = queue.find(input.job_id) || return NotFound.new
      JobDetail.new(row, Ops.current?.try(&.records(job_id: row.id)), Time.utc)
    end
  end

  # What a Command on a job answers.
  struct JobState
    include JSON::Serializable

    getter id : Int64
    getter state : String

    def initialize(@id, @state)
    end
  end

  # `POST /_punch/jobs/:job_id/retry`: runs a failed, discarded, or parked
  # job again with fresh attempts.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/jobs/:job_id/retry")]
  struct RetryJob < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter job_id : Int64
    end

    alias Output = JobState | NotFound | WrongState

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(RetryJob)) : Output
      queue = Job::Queue.current? || return NotFound.new
      return JobState.new(input.job_id, "ready") if queue.retry_job(input.job_id)

      queue.find(input.job_id).try { |row| WrongState.new(row.display_state(Time.utc)) } || NotFound.new
    end
  end

  # `POST /_punch/jobs/:job_id/discard`: discards a waiting, failed, or
  # parked job. A running job cannot be discarded.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/jobs/:job_id/discard")]
  struct DiscardJob < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter job_id : Int64
    end

    alias Output = JobState | NotFound | WrongState

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(DiscardJob)) : Output
      queue = Job::Queue.current? || return NotFound.new
      return JobState.new(input.job_id, "discarded") if queue.discard_job(input.job_id, "discarded in the ops console")

      queue.find(input.job_id).try { |row| WrongState.new(row.display_state(Time.utc)) } || NotFound.new
    end
  end

  struct Retried
    include JSON::Serializable

    getter job_type : String
    getter retried : Int64

    def initialize(@job_type, @retried)
    end
  end

  # `POST /_punch/jobs/retry_failed`: runs every failed job of one type
  # again.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/jobs/retry_failed")]
  struct RetryFailed < Punch::Command
    struct Input
      include Punch::Input

      # Not `type`: inside Punch::Input's macros `@type` is the input.
      getter job_type : String
    end

    alias Output = Retried | NotFound

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(RetryFailed)) : Output
      queue = Job::Queue.current? || return NotFound.new
      Retried.new(input.job_type, queue.retry_failed(input.job_type))
    end
  end

  struct QueueState
    include JSON::Serializable

    getter queue : String
    getter? paused : Bool

    def initialize(@queue, @paused)
    end
  end

  # `POST /_punch/queues/:queue/pause`: stops claiming from a queue in
  # every process; running jobs finish.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/queues/:queue/pause")]
  struct PauseQueue < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter queue : QueueName
    end

    alias Output = QueueState | NotFound

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(PauseQueue)) : Output
      queue = Job::Queue.current? || return NotFound.new
      queue.pause(input.queue.to_s)
      QueueState.new(input.queue.to_s, true)
    end
  end

  # `POST /_punch/queues/:queue/resume`.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/queues/:queue/resume")]
  struct ResumeQueue < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter queue : QueueName
    end

    alias Output = QueueState | NotFound

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(ResumeQueue)) : Output
      queue = Job::Queue.current? || return NotFound.new
      queue.resume(input.queue.to_s)
      QueueState.new(input.queue.to_s, false)
    end
  end

  # ---- Mail ---------------------------------------------------------------

  struct MailList
    include Punch::Component

    def initialize(@mails : Array(Mailer::Capture::Captured)?)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Mail") do
        v.h1 "Mail"
        mails = @mails
        if mails.nil?
          v.p "Mail is not captured in this process: the mail settings deliver it (delivery: smtp or adapter), or none are loaded."
        elsif mails.empty?
          v.p "No mail captured since this process started."
        else
          v.p "The newest #{Mailer::Capture::MAX} mails delivered by this process, kept in memory; nothing was sent."
          v.table(class: "mails") do
            v.thead { v.tr { ["Delivered", "To", "Subject", "Type"].each { |label| v.th label, scope: "col" } } }
            v.tbody do
              mails.each do |mail|
                v.tr do
                  v.td Console.time(mail.at)
                  v.td mail.to.join(", ")
                  v.td { v.a mail.subject.presence || "(no subject)", href: MailPage.href(mail_id: mail.id) }
                  v.td { v.code mail.type }
                end
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/mail`: the mail this process captured (`delivery:
  # capture`), newest first.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/mail")]
  struct MailsPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = MailList

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      MailList.new(Mailer.capture?.try(&.list))
    end
  end

  struct MailDetail
    include Punch::Component

    def initialize(@mail : Mailer::Capture::Captured)
    end

    def view(v : Punch::View) : Nil
      mail = @mail
      v.render Layout.new("Mail #{mail.id}") do
        v.h1 mail.subject.presence || "(no subject)"
        v.dl(class: "facts") do
          v.dt "From"
          v.dd mail.from
          v.dt "To"
          v.dd mail.to.join(", ")
          mail.reply_to.try { |reply_to| v.dt "Reply to"; v.dd reply_to }
          v.dt "Delivered"
          v.dd Console.time(mail.at)
          v.dt "Type"
          v.dd { v.code mail.type }
          v.dt "Locale"
          v.dd mail.locale
          v.dt "Job key"
          v.dd { v.code mail.key }
        end
        v.p { v.a "HTML part", href: MailHTMLPage.href(mail_id: mail.id) }
        v.h2 "Text part"
        v.pre mail.text
      end
    end
  end

  # `GET /_punch/mail/:mail_id`: one captured mail, its text part shown as
  # a mail client would.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/mail/:mail_id")]
  struct MailPage < Punch::Page
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter mail_id : Int64
    end

    alias Output = MailDetail | NotFound

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      mail = Mailer.capture?.try(&.find(input.mail_id)) || return NotFound.new
      MailDetail.new(mail)
    end
  end

  # The HTML part of a captured mail as the whole page.
  struct MailHTML
    include Punch::Component

    def initialize(@html : SafeHTML)
    end

    def view(v : Punch::HTMLView) : Nil
      v.raw @html
    end
  end

  # `GET /_punch/mail/:mail_id/html`: the HTML part of a captured mail,
  # as rendered by Punch's views.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch/mail/:mail_id/html")]
  struct MailHTMLPage < Punch::Page
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter mail_id : Int64
    end

    alias Output = MailHTML | NotFound

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      html = Mailer.capture?.try(&.find(input.mail_id)).try(&.html) || return NotFound.new
      MailHTML.new(html)
    end
  end

  # ---- Cache --------------------------------------------------------------

  # One store as this process sees it.
  record CacheStore, name : String, tier : String, ttl : Time::Span, shape : String, size : Int32,
    stats : Caches::Stats::Snapshot

  # The file's state: its bytes, its cap, and entries per store and shape.
  record CacheFile, bytes : Int64, max_bytes : Int64, usage : Array(Caches::Durable::Usage)

  struct CacheOverview
    include Punch::Component

    def initialize(@stores : Array(CacheStore), @file : CacheFile?, @enabled : Bool)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Cache") do
        v.h1 "Cache"
        v.p "Caching is off in this process (PUNCH_CACHE=off): every fetch computes." unless @enabled
        stores(v)
        file(v)
      end
    end

    private def stores(v : Punch::View) : Nil
      v.section do
        v.h2 "Stores"
        if @stores.empty?
          v.p "No store used since this process started. Stores are listed from their first use."
          return
        end
        v.p "Counters since this process started; memory entries are this process's."
        columns = ["Store", "Tier", "TTL", "In memory", "Memory hits", "File hits", "Misses", "Joined", "Hit rate",
                   "Compute ms", "Evicted", "Errors", ""]
        v.table(class: "stores") do
          v.thead { v.tr { columns.each { |label| v.th label, scope: "col" } } }
          v.tbody do
            @stores.each do |store|
              stats = store.stats
              v.tr do
                v.th store.name, scope: "row"
                v.td store.tier
                v.td store.ttl.to_s
                v.td store.size.to_s
                v.td stats.memory_hits.to_s
                v.td stats.durable_hits.to_s
                v.td stats.misses.to_s
                v.td stats.joins.to_s
                v.td(stats.hit_rate.try { |rate| "#{(rate * 100).round(1)} %" } || "–")
                v.td stats.compute_ms.to_s
                v.td stats.evictions.to_s
                v.td stats.errors.to_s
                v.td { clear(v, store.name) }
              end
            end
          end
        end
      end
    end

    private def file(v : Punch::View) : Nil
      v.section do
        v.h2 "cache.db"
        unless file = @file
          v.render Off.new("cache.db")
          return
        end
        v.p "#{(file.bytes / 1_048_576).round(2)} MiB of #{(file.max_bytes / 1_048_576).round(2)} MiB (PUNCH_CACHE_MB)."
        if file.usage.empty?
          v.p "No entries."
          return
        end
        v.table(class: "usage") do
          v.thead { v.tr { ["Store", "Shape", "Entries", "Expired", "Bytes", ""].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            file.usage.each do |usage|
              current = @stores.find { |store| store.name == usage.store }
              v.tr do
                v.th usage.store, scope: "row"
                v.td do
                  v.code usage.shape
                  # A shape this binary does not write: an earlier value
                  # type, read by nobody and trimmed as it expires.
                  v.text " (earlier shape)" if current && current.shape != usage.shape
                end
                v.td usage.entries.to_s
                v.td usage.expired.to_s
                v.td usage.bytes.to_s
                # Stores used in this process have their button above.
                v.td { clear(v, usage.store) unless current }
              end
            end
          end
        end
      end
    end

    private def clear(v : Punch::View, name : String) : Nil
      # Names were checked when the store was declared.
      if store = StoreName.parse(name).as?(StoreName)
        v.form(ClearCache.action(store: store)) { |form| form.submit "Clear #{name}" }
      end
    end
  end

  # `GET /_punch/cache`: every store used in this process, with its
  # counters and memory size, and what `cache.db` holds.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/cache")]
  @[Punch::Forms(ClearCache)]
  struct CachePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = CacheOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      stores = [] of CacheStore
      Caches.stores.each do |store|
        stores << CacheStore.new(store.name, store.tier.to_s.downcase, store.ttl, store.shape, store.size, store.stats.snapshot)
      end
      stores.sort_by!(&.name)
      file = Caches.durable.try do |durable|
        CacheFile.new(durable.bytes, durable.max_bytes, durable.usage(Time.utc))
      end
      CacheOverview.new(stores, file, Caches.enabled?)
    end
  end

  struct CacheCleared
    include JSON::Serializable

    getter store : String

    def initialize(@store)
    end
  end

  # `POST /_punch/cache/:store/clear`: removes a store's entries from this
  # process's memory and from `cache.db`. Another process's memory keeps
  # its entries until they expire.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("POST", "/_punch/cache/:store/clear")]
  struct ClearCache < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter store : StoreName
    end

    alias Output = CacheCleared | NotFound

    def call(input : Input, db : Punch::Writer, actor : Viewer, grant : Punch::Grant(ClearCache)) : Output
      name = input.store.to_s
      if store = Caches.stores.find { |one| one.name == name }
        store.clear
      else
        durable = Caches.durable || return NotFound.new
        durable.clear(name)
      end
      CacheCleared.new(name)
    end
  end
end

require "./console/*"
