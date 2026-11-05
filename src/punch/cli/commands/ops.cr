require "http/client"

module Punch::CLI::Commands
  # An ops report (`Punch::Ops::Reports`) as a command's result: its text
  # for people, its JSON, the same document the console's Query answers,
  # for programs.
  struct Shown(T)
    include Report

    def initialize(@report : T)
    end

    def to_text(io : IO) : Nil
      @report.to_text(io)
    end

    def to_json(json : JSON::Builder) : Nil
      @report.to_json(json)
    end
  end

  # Helpers shared by the ops commands. They read `ops.db` and `queue.db`
  # in `PUNCH_STORAGE` (docs/ops.md), also while the app runs, or, with
  # `--url`, a running app's ops console (`OpsRemote`).
  module OpsCommand
    # Runs *block* with the ops store, or answers without one.
    def self.with_store(& : Punch::Ops::Store -> Report | Failure) : Report | Failure
      settings = Config.settings
      return settings if settings.is_a?(Failure)

      path = File.join(settings.storage, "ops.db")
      return Failure.new("no_database", "#{path} does not exist; serve creates it unless PUNCH_OPS=off.") unless File.exists?(path)

      database = Punch::Database.open(path, name: "ops", config: Punch::Database::Config.new(readers: 1))
      begin
        yield Punch::Ops::Store.new(database)
      ensure
        database.close
      end
    rescue ex : Punch::Database::Error | Punch::Database::FilesystemError | Punch::Ops::Error
      Failure.new("database_error", ex.message || "database error")
    end

    # Runs *block* with whichever of the ops store and the queue exist, and
    # the storage directory.
    def self.with_files(& : Punch::Ops::Store?, Punch::Job::Queue?, String -> Report | Failure) : Report | Failure
      settings = Config.settings
      return settings if settings.is_a?(Failure)

      opened = [] of Punch::Database
      begin
        open = ->(name : String) do
          path = File.join(settings.storage, "#{name}.db")
          File.exists?(path) ? Punch::Database.open(path, name: name, config: Punch::Database::Config.new(readers: 1)).tap { |db| opened << db } : nil
        end
        store = open.call("ops").try { |database| Punch::Ops::Store.new(database) }
        queue = open.call("queue").try { |database| Punch::Job::Queue.new(database) }
        yield store, queue, settings.storage
      ensure
        opened.each(&.close)
      end
    rescue ex : Punch::Database::Error | Punch::Database::FilesystemError | Punch::Ops::Error | Punch::Job::Queue::Error
      Failure.new("database_error", ex.message || "database error")
    end

    # The remote app named by `--url URL` in *args* (both removed), or
    # `nil` for the local files.
    def self.remote(args : Array(String)) : OpsRemote? | Failure
      url = JobsCommand.option(args, "--url")
      return url if url.is_a?(Failure)

      url.try { |address| OpsRemote.parse(address, ENV[OpsRemote::TOKEN]?) }
    end

    # The ID in *args*, the only argument left.
    def self.id(args : Array(String), usage : String, what : String = "an error ID") : Int64 | Failure
      return Failure.usage("missing_argument", "Usage: #{usage}") if args.empty?
      return Failure.usage("unexpected_argument", "Usage: #{usage}") unless args.size == 1

      args[0].to_i64?.try { |id| id > 0 ? id : nil } || Failure.usage("invalid_id", "Not #{what}: #{args[0].inspect}")
    end

    # The number given with *name* in *args*, within *range*; *default*
    # without one.
    def self.limit(args : Array(String), range : Range(Int32, Int32), default : Int32, name : String = "--limit") : Int32 | Failure
      value = JobsCommand.option(args, name)
      return value if value.is_a?(Failure)
      return default unless value

      count = value.to_i?
      return Failure.usage("invalid_limit", "#{name} is a number from #{range.begin} to #{range.end}") unless count && range.includes?(count)

      count
    end

    # The member of *enum* given with *name* in *args*; *default* without
    # one.
    def self.choice(args : Array(String), name : String, default : E) : E | Failure forall E
      value = JobsCommand.option(args, name)
      return value if value.is_a?(Failure)
      return default unless value

      E.parse?(value) || Failure.usage("invalid_value", "#{name} is one of #{E.names.join(", ", &.downcase)}")
    end

    def self.usage(args : Array(String), usage : String) : Failure?
      Failure.usage("unexpected_argument", "Usage: #{usage}") unless args.empty?
    end

    # The answer of a local action on an error or job that did not apply:
    # 404 or 409 as the console answers it.
    def self.refused(what : String, id : Int64, state : String?) : Failure
      state ? Failure.new("wrong_state", "#{what} #{id} is #{state}.") : Failure.new("not_found", "No #{what.downcase} #{id}.")
    end
  end

  # The ops console's paths, which the remote commands read and post to.
  # A spec checks them against the console's routes.
  module OpsPaths
    OVERVIEW     = "/_punch"
    ERRORS       = "/_punch/errors"
    JOBS         = "/_punch/jobs"
    RETRY_FAILED = "/_punch/jobs/retry_failed"
    PERFORMANCE  = "/_punch/performance"

    def self.error(id : Int64, action : String? = nil) : String
      "#{ERRORS}/#{id}#{action.try { |name| "/#{name}" }}"
    end

    def self.job(id : Int64, action : String? = nil) : String
      "#{JOBS}/#{id}#{action.try { |name| "/#{name}" }}"
    end

    def self.record(id : Int64) : String
      "/_punch/records/#{id}"
    end
  end

  # A running app's ops console, read and acted on as JSON with the API
  # token of a user its policy admits, from `PUNCH_OPS_TOKEN` (never from
  # the command line, where it would land in the shell's history). The
  # answers are the reports the local commands print.
  #
  # Only the standalone `punch` binary reads remotely: in an app's binary,
  # which runs on the box, `--url` is refused, so neither `HTTP::Client`
  # nor the reports' JSON readers are compiled into every app (+60 MB of
  # compiler memory).
  class OpsRemote
    TOKEN = "PUNCH_OPS_TOKEN"

    getter url : URI

    def initialize(@url : URI, @token : String)
    end

    def self.parse(address : String, token : String?) : self | Failure
      {% unless ::Punch::CLI.has_constant?("TOOL_COMMANDS") %}
        return Failure.usage("remote_unavailable", "--url works in the punch binary; an app's binary reads the files on its box (drop --url).")
      {% end %}
      url = URI.parse(address)
      host = url.host.presence
      unless url.scheme.in?("http", "https") && host && url.query.nil?
        return Failure.usage("invalid_url", "--url takes the app's address, such as https://app.example.com")
      end
      if url.user || url.password
        return Failure.usage("invalid_url", "--url takes no credentials; the token comes from #{TOKEN}")
      end
      if url.scheme == "http" && !host.in?("localhost", "127.0.0.1", "[::1]", "::1")
        return Failure.usage("insecure_url", "--url over plain http only to this machine; the token would travel in the clear. Use https.")
      end
      unless token = token.presence
        return Failure.usage("missing_token", "Set #{TOKEN} to an API token of a user the ops console admits (punch tokens:create).")
      end

      new(url, token)
    end

    # The report of type *type* at *path*.
    def get(type : T.class, path : String, params : URI::Params = URI::Params.new) : T | Failure forall T
      {% if ::Punch::CLI.has_constant?("TOOL_COMMANDS") %}
        answer(type, request("GET", path, params, nil))
      {% else %}
        Failure.usage("remote_unavailable", "--url works in the punch binary")
      {% end %}
    end

    # Posts *body* to the Command at *path* and reads its answer as *type*.
    def post(type : T.class, path : String, body : String = "{}") : T | Failure forall T
      {% if ::Punch::CLI.has_constant?("TOOL_COMMANDS") %}
        answer(type, request("POST", path, URI::Params.new, body))
      {% else %}
        Failure.usage("remote_unavailable", "--url works in the punch binary")
      {% end %}
    end

    private def request(method : String, path : String, params : URI::Params, body : String?) : {Int32, String} | Failure
      client = ::HTTP::Client.new(@url)
      client.connect_timeout = 10.seconds
      client.read_timeout = 60.seconds
      headers = ::HTTP::Headers{"Accept" => "application/json", "Authorization" => "Bearer #{@token}"}
      headers["Content-Type"] = "application/json" if body
      target = "#{@url.path.rchop('/')}#{path}#{params.empty? ? "" : "?#{params}"}"
      begin
        response = method == "GET" ? client.get(target, headers) : client.post(target, headers, body)
        {response.status_code, response.body}
      ensure
        client.close
      end
    rescue ex : IO::Error
      Failure.new("unreachable", "#{@url}: #{ex.message}")
    end

    private def answer(type : T.class, result : {Int32, String} | Failure) : T | Failure forall T
      return result if result.is_a?(Failure)

      status, body = result
      if 200 <= status < 300
        begin
          return type.from_json(body)
        rescue JSON::ParseException | JSON::SerializableError
          return Failure.new("unexpected_answer", "#{@url} answered #{status} with something other than the report; is it a Punch app of this version with the ops console mounted?")
        end
      end
      problem = begin
        JSON.parse(body).as_h?
      rescue JSON::ParseException
        nil
      end
      code = problem.try(&.["code"]?).try(&.as_s?) || "http_#{status}"
      message = case code
                when "unauthenticated"
                  "#{@url} refused the token in #{TOKEN} (401)."
                when "not_found"
                  "#{@url} answered 404: no such entry, or no console for this token's user (the console does not show itself to users its policy refuses)."
                when "wrong_state"
                  "#{@url} answered 409: it is #{problem.try(&.["state"]?) || "in another state"}."
                when "unavailable"
                  "#{@url} answered 404: #{problem.try(&.["database"]?) || "the file"} is not open in that process."
                else
                  "#{@url} answered #{status} (#{code})."
                end
      Failure.new(code, message)
    end
  end

  # The state of the app at a glance.
  class OpsOverview < Command
    command "ops", "Show open errors, jobs per state, processes, requests in the last hour: punch ops [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      OpsCommand.usage(args, "punch ops [--url URL]").try { |failure| return failure }
      if remote
        report = remote.get(Punch::Ops::Reports::Overview, OpsPaths::OVERVIEW)
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      OpsCommand.with_files do |store, queue, storage|
        Shown.new(Punch::Ops::Reports::Overview.build(store, queue, Punch::Backup::Recovery.pending?(storage)))
      end
    end
  end

  # Lists error groups in `ops.db`, most recently seen first.
  class OpsErrors < Command
    command "ops:errors", "List errors recorded in ops.db: punch ops:errors [--resolved | --all] [--limit N] [--url URL]"

    USAGE = "punch ops:errors [--resolved | --all] [--limit N] [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      all = !args.delete("--all").nil?
      resolved = !args.delete("--resolved").nil?
      limit = OpsCommand.limit(args, 1..10_000, 50)
      return limit if limit.is_a?(Failure)

      OpsCommand.usage(args, USAGE).try { |failure| return failure }
      if remote
        params = URI::Params{"limit" => limit.to_s}
        params["all"] = "true" if all
        params["resolved"] = "true" if resolved
        report = remote.get(Punch::Ops::Reports::Errors, OpsPaths::ERRORS, params)
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      OpsCommand.with_store { |store| Shown.new(Punch::Ops::Reports::Errors.build(store, all ? nil : resolved, limit)) }
    end
  end

  # One error group with its backtrace and latest occurrences.
  class OpsError < Command
    command "ops:error", "Show one error with its backtrace and latest occurrences: punch ops:error ID [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      id = OpsCommand.id(args, "punch ops:error ID [--url URL]")
      return id if id.is_a?(Failure)

      if remote
        report = remote.get(Punch::Ops::Reports::ErrorDetail, OpsPaths.error(id))
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      OpsCommand.with_store do |store|
        Punch::Ops::Reports::ErrorDetail.build(store, id).try { |report| Shown.new(report) } || Failure.new("not_found", "No error #{id}.")
      end
    end
  end

  # Marks an error resolved; a new occurrence opens it again.
  class OpsResolve < Command
    command "ops:resolve", "Mark an error resolved; it opens again when it recurs: punch ops:resolve ID [--url URL]"

    def run(args : Array(String)) : Report | Failure
      OpsResolve.change(args, "resolve", "resolved")
    end

    # Resolves or reopens the error in *args*, here or remotely.
    def self.change(args : Array(String), action : String, state : String) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      id = OpsCommand.id(args, "punch ops:#{action} ID [--url URL]")
      return id if id.is_a?(Failure)

      if remote
        report = remote.post(Punch::Ops::Reports::Changed, OpsPaths.error(id, action))
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      OpsCommand.with_store do |store|
        changed = action == "resolve" ? store.resolve(id) : store.reopen(id)
        next Shown.new(Punch::Ops::Reports::Changed.new(id, state)) if changed
        OpsCommand.refused("Error", id, store.error(id).try { |group| group.resolved? ? "resolved" : "open" })
      end
    end
  end

  # Opens a resolved error again.
  class OpsReopen < Command
    command "ops:reopen", "Open a resolved error again: punch ops:reopen ID [--url URL]"

    def run(args : Array(String)) : Report | Failure
      OpsResolve.change(args, "reopen", "open")
    end
  end

  # Jobs as the console's jobs page shows them.
  class OpsJobs < Command
    command "ops:jobs", "Show jobs per queue and state, failed jobs by type, parked and running jobs, processes: punch ops:jobs [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      OpsCommand.usage(args, "punch ops:jobs [--url URL]").try { |failure| return failure }
      if remote
        report = remote.get(Punch::Ops::Reports::Jobs, OpsPaths::JOBS)
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      JobsCommand.with_queue { |queue, _| Shown.new(Punch::Ops::Reports::Jobs.build(queue)) }
    end
  end

  # One job with its payload, last error, and runs.
  class OpsJob < Command
    command "ops:job", "Show one job with its payload, last error, and its runs in ops.db: punch ops:job ID [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      id = OpsCommand.id(args, "punch ops:job ID [--url URL]", "a job ID")
      return id if id.is_a?(Failure)

      if remote
        report = remote.get(Punch::Ops::Reports::JobDetail, OpsPaths.job(id))
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      OpsCommand.with_files do |store, queue, _|
        next Failure.new("no_database", "queue.db does not exist; serve creates it.") unless queue
        Punch::Ops::Reports::JobDetail.build(queue, store, id).try { |report| Shown.new(report) } || Failure.new("not_found", "No job #{id}.")
      end
    end
  end

  # Runs a failed, discarded, or parked job again, or every failed job of
  # a type.
  class OpsRetry < Command
    command "ops:retry", "Run a failed, discarded, or parked job again, or every failed job of a type: punch ops:retry ID | --type TYPE [--url URL]"

    USAGE = "punch ops:retry ID | --type TYPE [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      type = JobsCommand.option(args, "--type")
      return type if type.is_a?(Failure)

      if type
        OpsCommand.usage(args, USAGE).try { |failure| return failure }
        return retry_failed(remote, type)
      end
      id = OpsCommand.id(args, USAGE, "a job ID")
      return id if id.is_a?(Failure)

      if remote
        report = remote.post(Punch::Ops::Reports::Changed, OpsPaths.job(id, "retry"))
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      JobsCommand.with_queue do |queue, _|
        next Shown.new(Punch::Ops::Reports::Changed.new(id, "ready")) if queue.retry_job(id)
        OpsCommand.refused("Job", id, queue.find(id).try(&.display_state(Time.utc)))
      end
    end

    private def retry_failed(remote : OpsRemote?, type : String) : Report | Failure
      if remote
        report = remote.post(Punch::Ops::Reports::Retried, OpsPaths::RETRY_FAILED, {job_type: type}.to_json)
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      JobsCommand.with_queue { |queue, _| Shown.new(Punch::Ops::Reports::Retried.new(type, queue.retry_failed(type))) }
    end
  end

  # Discards a waiting, failed, or parked job.
  class OpsDiscard < Command
    command "ops:discard", "Discard a waiting, failed, or parked job: punch ops:discard ID [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      id = OpsCommand.id(args, "punch ops:discard ID [--url URL]", "a job ID")
      return id if id.is_a?(Failure)

      if remote
        report = remote.post(Punch::Ops::Reports::Changed, OpsPaths.job(id, "discard"))
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      JobsCommand.with_queue do |queue, _|
        next Shown.new(Punch::Ops::Reports::Changed.new(id, "discarded")) if queue.discard_job(id, "discarded with punch ops:discard")
        OpsCommand.refused("Job", id, queue.find(id).try(&.display_state(Time.utc)))
      end
    end
  end

  # Time spent per route, job type, or named query.
  class OpsPerformance < Command
    command "ops:performance", "Show time per route, job type, or named query: punch ops:performance [--kind request|job|query] [--window hour|day|week] [--limit N] [--url URL]"

    USAGE = "punch ops:performance [--kind request|job|query] [--window hour|day|week] [--limit N] [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      kind = OpsCommand.choice(args, "--kind", Punch::Ops::StatsKind::Request)
      return kind if kind.is_a?(Failure)

      window = OpsCommand.choice(args, "--window", Punch::Ops::Window::Day)
      return window if window.is_a?(Failure)

      limit = OpsCommand.limit(args, 1..1_000, 200)
      return limit if limit.is_a?(Failure)

      OpsCommand.usage(args, USAGE).try { |failure| return failure }
      report = OpsPerformance.report(remote, kind, window, limit)
      report.is_a?(Failure) ? report : Shown.new(report)
    end

    # The performance report, here or remotely.
    def self.report(remote : OpsRemote?, kind : Punch::Ops::StatsKind, window : Punch::Ops::Window,
                    limit : Int32) : Punch::Ops::Reports::Performance | Failure
      if remote
        params = URI::Params{"kind" => kind.to_s.downcase, "window" => window.to_s.downcase, "limit" => limit.to_s}
        return remote.get(Punch::Ops::Reports::Performance, OpsPaths::PERFORMANCE, params)
      end
      found = nil
      outcome = OpsCommand.with_store do |store|
        found = Punch::Ops::Reports::Performance.build(store, kind, window, limit)
        Shown.new(found)
      end
      found || outcome.as(Failure)
    end
  end

  # The slowest requests kept, failed ones included.
  class OpsSlow < Command
    command "ops:slow", "Show the slowest requests kept (failed, or from PUNCH_OPS_SLOW_MS): punch ops:slow [--window hour|day|week] [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      window = OpsCommand.choice(args, "--window", Punch::Ops::Window::Day)
      return window if window.is_a?(Failure)

      OpsCommand.usage(args, "punch ops:slow [--window hour|day|week] [--url URL]").try { |failure| return failure }
      report = OpsPerformance.report(remote, Punch::Ops::StatsKind::Request, window, 1)
      report.is_a?(Failure) ? report : Shown.new(Punch::Ops::Reports::SlowRequests.new(report))
    end
  end

  # One stored wide event.
  class OpsRecord < Command
    command "ops:record", "Show one stored wide event (a failed or slow request, a job run), every field: punch ops:record ID [--url URL]"

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      remote = OpsCommand.remote(args)
      return remote if remote.is_a?(Failure)

      id = OpsCommand.id(args, "punch ops:record ID [--url URL]", "a record ID")
      return id if id.is_a?(Failure)

      if remote
        report = remote.get(Punch::Ops::Reports::WideEvent, OpsPaths.record(id))
        return report.is_a?(Failure) ? report : Shown.new(report)
      end
      OpsCommand.with_store do |store|
        store.record(id).try { |record| Shown.new(Punch::Ops::Reports::WideEvent.new(record)) } || Failure.new("not_found", "No record #{id}.")
      end
    end
  end
end
