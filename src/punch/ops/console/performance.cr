module Punch::Ops::Console
  # ---- Performance --------------------------------------------------------

  # A duration in milliseconds as the console shows it.
  def self.ms(value : Float64?) : String
    return "–" unless value

    value >= 100 ? "#{value.round.to_i64} ms" : "#{value.round(2)} ms"
  end

  # The class that makes a bar *share* of its track long (`console.css`:
  # `w-0` to `w-100` in steps of 2). Anything above zero shows.
  def self.width(share : Float64) : String
    "w-#{steps(share, least: 2)}"
  end

  # The class that starts a bar at *share* of its track (`at-0` to
  # `at-100`).
  def self.offset(share : Float64) : String
    "at-#{steps(share)}"
  end

  private def self.steps(share : Float64, least : Int32 = 0) : Int32
    return 0 unless share > 0 # also NaN
    Math.max(least, (share.clamp(0.0, 1.0) * 50).round.to_i * 2)
  end

  # Where a stored wide event's time went, as bars for browsers (the
  # numbers are in the event): for a job, the wait in the queue and then
  # the run; within the run, the time spent in database statements,
  # waiting for the writer, and computing cache entries. ops.db keeps no
  # child spans, so those three are totals, not positions.
  struct Timing
    include Punch::Component

    PARTS = {
      "punch.db.duration_ms"    => "Database",
      "punch.db.writer_wait_ms" => "Writer wait",
      "punch.cache.compute_ms"  => "Cache compute",
    }

    def initialize(@record : StoredRecord)
    end

    def view(v : Punch::View) : Nil
      duration = @record.duration_ms || return
      fields = JSON.parse(@record.fields).as_h? || return
      queued = number(fields, "punch.job.latency_ms") || 0.0
      scale = queued + duration
      return unless scale > 0

      parts = PARTS.compact_map { |key, label| number(fields, key).try { |spent| {label, spent} } }
      v.chrome do |html|
        html.table(class: "timing", aria: {label: "Timing"}) do
          html.tbody do
            row(html, "Queued", "wait", queued, 0.0, scale) if queued > 0
            row(html, @record.kind == "job" ? "Run" : "Request", @record.failed ? "failed" : "run", duration, queued, scale)
            parts.each { |label, spent| row(html, label, "part", spent, queued, scale) }
          end
        end
        html.p "The bars below the run are totals within it, not when they happened.", class: "note" unless parts.empty?
      end
    end

    private def row(v : Punch::View, label : String, tone : String, ms : Float64, start : Float64, scale : Float64) : Nil
      v.tr(class: tone) do
        v.th label, scope: "row"
        v.td Console.ms(ms)
        v.td(class: "timeline") do
          v.span(class: "track") { v.span(class: "bar #{Console.offset(start / scale)} #{Console.width(ms / scale)}") { } }
        end
      end
    end

    private def number(fields : Hash(String, JSON::Any), key : String) : Float64?
      value = fields[key]?.try(&.raw)
      case value
      when Float64 then value
      when Int64   then value.to_f
      end
    end
  end

  # A row's p50, p95, and p99 as bars against *scale*, the longest p99 in
  # its table; for browsers, as the numbers are in the row.
  struct Spread
    include Punch::Component

    QUANTILES = {0.99 => "p99", 0.95 => "p95", 0.5 => "p50"}

    def initialize(@stats : Stats, @scale : Float64)
    end

    def view(v : Punch::View) : Nil
      return unless @scale > 0

      v.chrome do |html|
        html.span(class: "spread", aria: {hidden: true}) do
          QUANTILES.each do |quantile, name|
            value = @stats.percentile(quantile) || next
            html.span(class: "#{name} #{Console.width(value / @scale)}") { }
          end
        end
      end
    end

    # The longest p99 of *rows*: the scale of their spreads.
    def self.scale(rows : Array(Stats)) : Float64
      rows.max_of? { |row| row.percentile(0.99) || 0.0 } || 0.0
    end
  end

  # The links that switch kind and window.
  struct PerformanceTabs
    include Punch::Component

    def initialize(@kind : StatsKind, @window : Window)
    end

    def view(v : Punch::View) : Nil
      v.nav(class: "tabs", aria: {label: "What and when"}) do
        StatsKind.each do |kind|
          if kind == @kind
            v.strong kind.title
          else
            v.a kind.title, href: PerformancePage.href(kind: kind, window: @window)
          end
          v.text " "
        end
        v.text "· "
        Window.each do |window|
          if window == @window
            v.strong window.label
          else
            v.a window.label, href: PerformancePage.href(kind: @kind, window: window)
          end
          v.text " "
        end
      end
    end
  end

  struct PerformanceOverview
    include Punch::Component

    def initialize(@kind : StatsKind, @window : Window, @stats : Array(Stats)?, @slowest : Array(StoredRecord)?)
    end

    def view(v : Punch::View) : Nil
      title = "#{@kind.title}, #{@window.label}"
      v.render Layout.new("Performance") do
        v.h1 "Performance"
        v.render PerformanceTabs.new(@kind, @window)
        stats = @stats
        unless stats
          v.render Off.new("ops.db")
          next
        end
        v.section do
          v.h2 title
          if stats.empty?
            v.p "Nothing recorded #{@window.label}."
          else
            v.p "The most time spent first. Percentiles are the upper bound of the duration bucket they fall in."
            table(v, stats)
          end
        end
        @slowest.try { |slowest| slowest_requests(v, slowest) }
      end
    end

    private def table(v : Punch::View, stats : Array(Stats)) : Nil
      runs = @kind.query? ? "Statements" : "Runs"
      extra = @kind.query? ? ["Rows per run"] : ["Writer wait", "Queries per run"]
      extra << "Replayed" if @kind.request?
      columns = ["Name", runs, "Failed", "p50", "p95", "p99", "Max", "Average", "Total"] + extra
      scale = Spread.scale(stats)
      v.table(class: "stats") do
        v.thead { v.tr { columns.each { |label| v.th label, scope: "col" } } }
        v.tbody do
          stats.each do |row|
            v.tr do
              v.th(scope: "row") do
                v.a row.name, href: SeriesPage.href(kind: @kind, name: row.name, window: @window)
                v.render Spread.new(row, scale)
              end
              v.td row.count.to_s
              v.td row.failed.to_s
              v.td Console.ms(row.percentile(0.5))
              v.td Console.ms(row.percentile(0.95))
              v.td Console.ms(row.percentile(0.99))
              v.td Console.ms(row.max_ms)
              v.td Console.ms(row.average_ms)
              v.td "#{(row.total_ms / 1000).round(2)} s"
              if @kind.query?
                v.td (row.rows / Math.max(row.count, 1)).to_s
              else
                v.td Console.ms(row.count > 0 ? row.wait_ms / row.count : nil)
                v.td (row.count > 0 ? (row.queries / row.count).round(1) : 0).to_s
              end
              v.td row.replays.to_s if @kind.request?
            end
          end
        end
      end
    end

    private def slowest_requests(v : Punch::View, slowest : Array(StoredRecord)) : Nil
      v.section do
        v.h2 "Slowest requests"
        if slowest.empty?
          v.p "None kept #{@window.label}: requests are kept when they fail or take PUNCH_OPS_SLOW_MS or longer."
          return
        end
        longest = slowest.max_of? { |record| record.duration_ms || 0.0 } || 0.0
        v.table(class: "slowest") do
          v.thead { v.tr { ["Started", "Request", "Duration", "Status", "Trace"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            slowest.each do |record|
              status = JSON.parse(record.fields)["http.response.status_code"]?.try(&.as_i64?)
              v.tr do
                v.td Console.time(record.at)
                v.td { v.a record.name, href: RecordPage.href(record_id: record.id) }
                v.td do
                  v.text Console.ms(record.duration_ms)
                  record.duration_ms.try do |duration|
                    v.chrome { |html| html.span(class: "track length", aria: {hidden: true}) { html.span(class: "bar #{Console.width(duration / longest)}") { } } } if longest > 0
                  end
                end
                v.td status.try(&.to_s) || "–"
                v.td { record.trace_id.try { |id| v.code id } }
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/performance`: requests by route, job runs by type, or
  # named queries (`?kind=query`), over the last hour, day, or week
  # (`?window=hour`), with the slowest requests kept.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/performance")]
  struct PerformancePage < Punch::Page
    struct Input
      include Punch::Input

      getter kind : StatsKind = StatsKind::Request
      getter window : Window = Window::Day
    end

    alias Output = PerformanceOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current? || return PerformanceOverview.new(input.kind, input.window, nil, nil)
      since = Time.utc - input.window.span
      slowest = input.kind.request? ? store.slowest(since: since) : nil
      PerformanceOverview.new(input.kind, input.window, store.stats(input.kind.to_s.downcase, since: since), slowest)
    end
  end

  struct SeriesDetail
    include Punch::Component

    def initialize(@kind : StatsKind, @name : String, @window : Window, @series : Array(Stats))
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new(@name) do
        v.h1 @name
        v.p do
          v.text "#{@kind.title}, #{@window.label}, per #{BUCKET.total_minutes.to_i} minutes. "
          v.a "All #{@kind.title.downcase}", href: PerformancePage.href(kind: @kind, window: @window)
        end
        if @series.empty?
          v.p "Nothing recorded #{@window.label}."
          next
        end
        scale = Spread.scale(@series)
        v.table(class: "series") do
          v.thead { v.tr { ["From", "Runs", "Failed", "p50", "p95", "p99", "Max", "Average"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            @series.reverse_each do |row|
              v.tr do
                v.td do
                  v.text Console.time(row.bucket)
                  v.render Spread.new(row, scale)
                end
                v.td row.count.to_s
                v.td row.failed.to_s
                v.td Console.ms(row.percentile(0.5))
                v.td Console.ms(row.percentile(0.95))
                v.td Console.ms(row.percentile(0.99))
                v.td Console.ms(row.max_ms)
                v.td Console.ms(row.average_ms)
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/performance/series?kind=query&name=…`: one route, job
  # type, or named query per stats bucket, newest first.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/performance/series")]
  struct SeriesPage < Punch::Page
    struct Input
      include Punch::Input

      getter kind : StatsKind
      getter name : String
      getter window : Window = Window::Day
    end

    alias Output = SeriesDetail | NotFound

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current? || return NotFound.new
      series = store.series(input.kind.to_s.downcase, input.name, since: Time.utc - input.window.span)
      SeriesDetail.new(input.kind, input.name, input.window, series)
    end
  end

  struct RecordDetail
    include Punch::Component

    def initialize(@record : StoredRecord)
    end

    def view(v : Punch::View) : Nil
      record = @record
      v.render Layout.new(record.name) do
        v.h1 record.name
        v.dl(class: "facts") do
          v.dt "Started"
          v.dd Console.time(record.at)
          v.dt "Duration"
          v.dd Console.ms(record.duration_ms)
          v.dt "Failed"
          v.dd record.failed ? "yes" : "no"
          record.trace_id.try { |id| v.dt "Trace"; v.dd { v.code id } }
          record.job_id.try { |id| v.dt "Job"; v.dd { v.a id.to_s, href: JobPage.href(job_id: id) } }
        end
        v.render Timing.new(record)
        v.h2 "Wide event"
        v.dl(class: "event") do
          JSON.parse(record.fields).as_h.each do |key, value|
            v.dt key
            v.dd { v.code value.as_s? || value.to_json }
          end
        end
      end
    end
  end

  # `GET /_punch/records/:record_id`: one stored wide event, every field.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/records/:record_id")]
  struct RecordPage < Punch::Page
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter record_id : Int64
    end

    alias Output = RecordDetail | NotFound

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      record = Ops.current?.try(&.record(input.record_id)) || return NotFound.new
      RecordDetail.new(record)
    end
  end
end
