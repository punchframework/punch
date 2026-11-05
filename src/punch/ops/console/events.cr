module Punch::Ops::Console
  # ---- Events -------------------------------------------------------------

  # A subscriber of an event and what it did in the window: a deferred
  # one's job runs, an after-commit one's open errors.
  record SubscriberState, name : String, delivery : String, runs : Int64?, failed : Int64?, open_errors : Int64

  # One event type: committed in the window, its publishers, its
  # subscribers.
  record EventState, event : String, committed : Int64, last : Time?, publishers : Array(String),
    subscribers : Array(SubscriberState)

  struct EventsOverview
    include Punch::Component

    def initialize(@events : Array(EventState)?, @latest : Array(EventRecord)?, @backlog : {Int64, Time?}?, @now : Time)
    end

    def view(v : Punch::View) : Nil
      v.render Layout.new("Events") do
        v.h1 "Events"
        outbox(v)
        types(v)
        latest(v)
      end
    end

    private def outbox(v : Punch::View) : Nil
      v.section do
        v.h2 "Outbox"
        if backlog = @backlog
          pending, oldest = backlog
          v.dl(class: "summary") do
            v.dt "Waiting to be handed over"
            v.dd pending.to_s
            v.dt "Oldest waiting"
            v.dd oldest ? "#{Console.time(oldest)} (#{(@now - oldest).total_seconds.round(1)} s)" : "–"
          end
        else
          v.p "The primary database has no outbox: no Command enqueues jobs and no subscriber is deferred."
        end
      end
    end

    private def types(v : Punch::View) : Nil
      v.section do
        v.h2 "Event types, last 24 hours"
        events = @events
        if events.nil?
          v.render Off.new("ops.db")
          return
        end
        if events.empty?
          v.p "This app declares no events."
          return
        end
        v.p "Committed events are counted for the share of traces PUNCH_OPS_SAMPLE_PERCENT keeps."
        v.table(class: "events") do
          v.thead { v.tr { ["Event", "Committed", "Last", "Published by", "Subscribers"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            events.each do |state|
              v.tr do
                v.th { v.code state.event }
                v.td state.committed.to_s
                v.td Console.time(state.last)
                v.td { state.publishers.each { |publisher| v.code publisher; v.br } }
                v.td { state.subscribers.each { |subscriber| subscriber(v, subscriber) } }
              end
            end
          end
        end
      end
    end

    private def subscriber(v : Punch::View, subscriber : SubscriberState) : Nil
      v.code subscriber.name
      v.text " (#{subscriber.delivery.gsub('_', ' ')})"
      if (runs = subscriber.runs) && (failed = subscriber.failed)
        v.text ": #{runs} runs, #{failed} failed"
      end
      v.text ", #{subscriber.open_errors} open errors" if subscriber.open_errors > 0
      v.br
    end

    private def latest(v : Punch::View) : Nil
      v.section do
        v.h2 "Latest"
        latest = @latest || return
        if latest.empty?
          v.p "No event recorded."
          return
        end
        v.table(class: "latest") do
          v.thead { v.tr { ["Committed", "Event", "By", "Trace"].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            latest.each do |event|
              v.tr do
                v.td Console.time(event.at)
                v.td { v.code event.event }
                v.td { v.code event.source }
                v.td { event.trace_id.try { |id| v.code id } }
              end
            end
          end
        end
      end
    end
  end

  # `GET /_punch/events`: the outbox's backlog, each event type with how
  # often it was committed, who publishes it, and how its subscribers
  # fared, and the latest committed events.
  @[Punch::Authorize(Access)]
  @[Punch::Unlisted]
  @[Punch::AgentReadable]
  @[Punch::Route("GET", "/_punch/events")]
  struct EventsPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = EventsOverview

    def call(input : Input, db : Punch::Reader, actor : Viewer) : Output
      store = Ops.current?
      now = Time.utc
      backlog = Job::Outbox.backlog(db)
      return EventsOverview.new(nil, nil, backlog, now) unless store

      since = now - 24.hours
      counts = store.event_counts(since: since).to_h { |event, count, last| {event, {count, last}} }
      jobs = store.stats("job", since: since).to_h { |stats| {stats.name, stats} }
      errors = store.errors(limit: 1000).group_by(&.source)
      states = Subscribers.graph.map do |node|
        subscribers = node.subscribers.map do |name, delivery|
          runs = delivery == "deferred" ? jobs["job #{name}(#{node.event})"]? : nil
          SubscriberState.new(name, delivery, runs.try(&.count) || (delivery == "deferred" ? 0_i64 : nil),
            runs.try(&.failed) || (delivery == "deferred" ? 0_i64 : nil), errors[name]?.try(&.size.to_i64) || 0_i64)
        end
        committed, last = counts[node.event]? || {0_i64, nil}
        EventState.new(node.event, committed, last, node.publishers, subscribers)
      end
      EventsOverview.new(states, store.events(limit: 50), backlog, now)
    end
  end
end
