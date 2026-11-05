module Punch::Ops::Console
  # ---- JSON ---------------------------------------------------------------
  #
  # The reports `punch ops` prints (`Punch::Ops::Reports`), answered as
  # JSON on the console's own paths: a browser gets the page, an agent
  # asking for markdown its markdown, a program the Query. `punch ops:*
  # --url` reads these with an operator's API token.

  # 404: the file the report reads is not open in this process
  # (`PUNCH_OPS=off`, or a binary that does not serve).
  @[Punch::Status(404)]
  struct Unavailable
    include JSON::Serializable

    getter database : String

    def initialize(@database)
    end
  end

  # `GET /_punch` as JSON: the overview.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch")]
  struct ShowOverview < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = Reports::Overview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      recovering = Backup.storage.try { |storage| Backup::Recovery.pending?(storage) } || false
      Reports::Overview.build(Ops.current?, Job::Queue.current?, recovering)
    end
  end

  # `GET /_punch/errors` as JSON: open errors, resolved ones
  # (`?resolved=true`), or all (`?all=true`), up to `limit`.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch/errors")]
  struct ListErrors < Punch::Query
    struct Input
      include Punch::Input

      getter? resolved : Bool = false
      getter? all : Bool = false
      getter limit : Int32 = 50
    end

    alias Output = Reports::Errors | Unavailable

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current? || return Unavailable.new("ops.db")
      Reports::Errors.build(store, input.all? ? nil : input.resolved?, input.limit.clamp(1, 10_000))
    end
  end

  # `GET /_punch/errors/:error_id` as JSON.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch/errors/:error_id")]
  struct ShowError < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter error_id : Int64
    end

    alias Output = Reports::ErrorDetail | NotFound | Unavailable

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current? || return Unavailable.new("ops.db")
      Reports::ErrorDetail.build(store, input.error_id) || NotFound.new
    end
  end

  # `GET /_punch/jobs` as JSON.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch/jobs")]
  struct ShowJobs < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = Reports::Jobs | Unavailable

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      queue = Job::Queue.current? || return Unavailable.new("queue.db")
      Reports::Jobs.build(queue)
    end
  end

  # `GET /_punch/jobs/:job_id` as JSON.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch/jobs/:job_id")]
  struct ShowJob < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter job_id : Int64
    end

    alias Output = Reports::JobDetail | NotFound | Unavailable

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      queue = Job::Queue.current? || return Unavailable.new("queue.db")
      Reports::JobDetail.build(queue, Ops.current?, input.job_id) || NotFound.new
    end
  end

  # `GET /_punch/performance` as JSON, with the slowest requests kept
  # when `kind` is `request`.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch/performance")]
  struct ShowPerformance < Punch::Query
    struct Input
      include Punch::Input

      getter kind : StatsKind = StatsKind::Request
      getter window : Window = Window::Day
      getter limit : Int32 = 200
    end

    alias Output = Reports::Performance | Unavailable

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current? || return Unavailable.new("ops.db")
      Reports::Performance.build(store, input.kind, input.window, input.limit.clamp(1, 1_000))
    end
  end

  # `GET /_punch/records/:record_id` as JSON.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::Route("GET", "/_punch/records/:record_id")]
  struct ShowRecord < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter record_id : Int64
    end

    alias Output = Reports::WideEvent | NotFound | Unavailable

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current? || return Unavailable.new("ops.db")
      store.record(input.record_id).try { |record| Reports::WideEvent.new(record) } || NotFound.new
    end
  end
end
