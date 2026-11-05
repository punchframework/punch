require "log"
require "random/secure"

module Punch
  # Live updates: committed events reach the pages people have open, as
  # Turbo Stream actions over server-sent events.
  #
  # A page that defines `live` is a live page. Its HTML carries a
  # `<turbo-stream-source>` pointing at its own URL; Turbo opens it with
  # `Accept: text/event-stream`, and the router answers with a stream that
  # stays open. Every committed event the page's `live` takes is handed to
  # each open stream, which asks the page's policy again and calls `live`
  # for its own viewer, in a read transaction of its own (docs/views.md,
  # "Live pages").
  #
  # Events travel through a `Live::Hub`: in-process, since Punch runs on
  # one node. Events committed in another process (a separate `punch jobs`)
  # do not reach this one's streams.
  module Live
    Log = ::Log.for("punch.live")

    # The media type of a live page's stream.
    MEDIA_TYPE = "text/event-stream"

    # The query parameter that tells a stream which events the page it
    # belongs to has already seen.
    PARAM = "_live"

    # One event as the hub hands it out: its place in this hub's order and
    # the event.
    record Entry, sequence : Int64, event : Event

    # Where a stream starts: the events after a position the page has
    # seen, or a refresh when the hub no longer holds them all.
    alias Since = Array(Entry) | Refresh

    # The hub cannot replay what a page missed: it asks Turbo to fetch the
    # page again.
    struct Refresh
    end

    # How streams learn about events. One implementation, `InProcess`; the
    # interface keeps the router and the streams independent of it.
    abstract class Hub
      # Hands a committed *event* to every subscription that takes it.
      abstract def publish(event : Event) : Nil

      # A subscription for the events *takes* accepts.
      abstract def subscribe(takes : Event -> Bool) : Subscription

      abstract def unsubscribe(subscription : Subscription) : Nil

      # The position after the last event published: written into a live
      # page before its read transaction starts.
      abstract def position : String

      # The position right after *entry*: a stream's event ID.
      abstract def position(entry : Entry) : String

      # The events *takes* accepts after *position*, or `Refresh` when
      # *position* is from another process or older than what the hub
      # keeps.
      abstract def since(position : String?, takes : Event -> Bool) : Since

      # Ends every subscription: streams close and browsers reconnect,
      # to the next process during a deploy.
      abstract def close : Nil
    end

    # Events for one stream, waiting to be rendered. When the stream falls
    # too far behind (a slow client, a burst of events), it is marked
    # overflowed and refreshes the page instead.
    class Subscription
      CAPACITY = 64

      getter takes : Event -> Bool
      getter channel = Channel(Entry).new(CAPACITY)
      @overflowed = Atomic(Bool).new(false)

      def initialize(@takes : Event -> Bool)
      end

      # Offers *entry* without waiting.
      # :nodoc:
      def offer(entry : Entry) : Nil
        select
        when channel.send(entry)
        else
          @overflowed.set(true)
        end
      rescue Channel::ClosedError
      end

      # Whether entries were dropped since the last call.
      def overflowed! : Bool
        @overflowed.swap(false)
      end

      def close : Nil
        channel.close
      end

      def closed? : Bool
        channel.closed?
      end
    end

    # The in-process hub: subscriptions in a list, and the last `BACKLOG`
    # events kept so a stream can catch up with what happened between the
    # page's read and its connection, or while it reconnected.
    class InProcess < Hub
      BACKLOG = 1024

      # The most events one stream replays when it opens; with more, it
      # refreshes the page instead, so that opening a stream from an old
      # position does not run `live` a thousand times.
      MAX_REPLAY = 64

      # Identifies this process's positions: one from another process (the
      # one before a deploy) cannot be caught up with.
      getter boot : String = Random::Secure.hex(4)
      @sequence = 0_i64
      @backlog = Deque(Entry).new
      @subscriptions = [] of Subscription
      @lock = Mutex.new
      @closed = false

      def publish(event : Event) : Nil
        @lock.synchronize do
          return if @closed

          @sequence += 1
          entry = Entry.new(@sequence, event)
          @backlog.shift if @backlog.size >= BACKLOG
          @backlog << entry
          @subscriptions.each do |subscription|
            subscription.offer(entry) if subscription.takes.call(event)
          end
        end
      end

      def subscribe(takes : Event -> Bool) : Subscription
        subscription = Subscription.new(takes)
        @lock.synchronize do
          if @closed
            subscription.close
          else
            @subscriptions << subscription
          end
        end
        subscription
      end

      def unsubscribe(subscription : Subscription) : Nil
        @lock.synchronize { @subscriptions.delete(subscription) }
        subscription.close
      end

      def position : String
        @lock.synchronize { "#{boot}-#{@sequence}" }
      end

      def position(entry : Entry) : String
        "#{boot}-#{entry.sequence}"
      end

      def since(position : String?, takes : Event -> Bool) : Since
        return [] of Entry unless position

        from, _, number = position.partition('-')
        sequence = number.to_i64? || return Refresh.new
        @lock.synchronize do
          return Refresh.new unless from == boot && 0 <= sequence <= @sequence

          oldest = @backlog.first?.try(&.sequence) || @sequence + 1
          return Refresh.new if sequence + 1 < oldest

          missed = @backlog.select { |entry| entry.sequence > sequence && takes.call(entry.event) }
          missed.size > MAX_REPLAY ? Refresh.new : missed
        end
      end

      def close : Nil
        subscriptions = @lock.synchronize do
          @closed = true
          @subscriptions.dup.tap { @subscriptions.clear }
        end
        subscriptions.each(&.close)
      end

      # Opens the hub again after `close`, for specs that stop a server.
      # :nodoc:
      def reopen : Nil
        @lock.synchronize { @closed = false }
      end

      # How many streams are open.
      def subscribers : Int32
        @lock.synchronize { @subscriptions.size }
      end
    end

    class_property hub : Hub = InProcess.new

    # How many streams may be open at once in this process; one more is
    # answered 503. Each holds a connection and a fiber. At most three
    # quarters of the server's `max_connections`, so that other requests,
    # `/up` among them, still find one.
    class_property max_streams : Int32 = {1000, HTTP::Config.connection_limit * 3 // 4}.min

    # How many of them one viewer may hold: a signed-in user, or for a
    # page without an actor the client's address. One more is answered
    # 503.
    class_property max_streams_per_viewer : Int32 = 16

    # How often an idle stream sends a comment, so proxies keep it and a
    # gone client is noticed.
    class_property keepalive : Time::Span = 15.seconds

    @@open = Atomic(Int32).new(0)
    @@viewers = Hash(String, Int32).new(0)
    @@viewers_lock = Mutex.new

    # Publishes a committed *event*, from the after-commit delivery
    # (`Subscribers.publish`), only for events some live page takes.
    def self.publish(event : Event) : Nil
      hub.publish(event)
    rescue ex
      Log.error(exception: ex) { "live: publishing #{event.class} failed" }
    end

    # Whether *context*'s request asks for a live page's stream: the
    # browser's `EventSource` sends `Accept: text/event-stream`.
    def self.requested?(context : HTTP::Context) : Bool
      context.request.method == "GET" && !!context.request.headers["Accept"]?.try(&.includes?(MEDIA_TYPE))
    end

    # The URL a live page's `<turbo-stream-source>` opens: the page's own,
    # with the hub's *position* when the page was read.
    def self.source(resource : String, position : String) : String
      uri = URI.parse(resource)
      params = uri.query_params
      params.delete_all(PARAM)
      params.add(PARAM, position)
      uri.query = params.to_s
      uri.to_s
    end

    # What a stream renders for one event: actions for the viewer, nothing
    # when the page shows nothing of it, or `Ended` when the viewer may no
    # longer see the page. Without an event, only the last: whether the
    # viewer may still see it.
    alias Turn = SafeHTML | Ended?

    struct Ended
    end

    # Opens a stream for a live page. *takes* filters events by type,
    # *turn* renders one for the viewer, or without an event checks that
    # they may still see the page. Answers 503 when `max_streams` are
    # open, or `max_streams_per_viewer` for this viewer.
    def self.respond(context : HTTP::Context, takes : Event -> Bool, turn : Event? -> Turn) : HTTP::Response
      viewer = context.principal.try { |principal| "user #{principal.user_id}" } || "address #{context.client_ip}"
      unless claim(viewer)
        context.span.set("punch.outcome", "live_streams_exhausted")
        response = HTTP::Response.problem(:service_unavailable, context, "live_streams_exhausted")
        response.headers["Retry-After"] = "30"
        return response
      end
      begin
        # The page's position: after a reconnect the browser's last event,
        # otherwise the one written into the page.
        position = context.request.headers["Last-Event-ID"]? || context.request.query_params[PARAM]?
        subscription = hub.subscribe(takes)
        since = hub.since(position, takes)
        context.span.set("punch.surface", "live")
        HTTP::Response.live(Connection.new(subscription, since, turn, context.tracer, context.request.path, viewer))
      rescue ex
        closed(viewer)
        raise ex
      end
    end

    # Takes a slot for one of *viewer*'s streams, unless the process or
    # the viewer holds all they may.
    private def self.claim(viewer : String) : Bool
      @@viewers_lock.synchronize do
        return false if @@viewers[viewer] >= max_streams_per_viewer
        if @@open.add(1) >= max_streams
          @@open.sub(1)
          return false
        end
        @@viewers[viewer] += 1
        true
      end
    end

    protected def self.closed(viewer : String) : Nil
      @@viewers_lock.synchronize do
        @@open.sub(1)
        left = @@viewers[viewer] - 1
        left > 0 ? (@@viewers[viewer] = left) : @@viewers.delete(viewer)
      end
    end

    # One open stream: writes the catch-up, then each event's actions as
    # they come, until the client goes away, the viewer loses access, or
    # the hub closes.
    class Connection
      @stopped = Channel(Nil).new

      def initialize(@subscription : Subscription, @since : Since, @turn : Event? -> Turn, @tracer : Trace::Tracer?, @path : String, @viewer : String)
      end

      # Ends the stream from outside, as a spec's client does.
      def stop : Nil
        @stopped.close
      end

      # Releases a stream that will never run: a spec's plain request that
      # happened to ask for one.
      def discard : Nil
        Live.hub.unsubscribe(@subscription)
        Live.closed(@viewer)
      end

      # Runs the stream on *io* until it ends.
      def run(io : IO) : Nil
        last = 0_i64
        # Tells EventSource how long to wait before reconnecting.
        io << "retry: 2000\n\n"
        io.flush

        case since = @since
        in Refresh
          write(io, nil, Live.refresh)
        in Array(Entry)
          since.each do |entry|
            last = entry.sequence
            return unless deliver(io, entry)
          end
        end

        loop do
          select
          when entry = @subscription.channel.receive?
            break unless entry
            if @subscription.overflowed!
              # Too far behind to render each: Turbo fetches the page.
              drain
              write(io, nil, Live.refresh)
              next
            end
            next if entry.sequence <= last
            last = entry.sequence
            break unless deliver(io, entry)
          when @stopped.receive?
            break
          when timeout(Live.keepalive)
            break unless allowed?
            io << ":\n\n"
            io.flush
          end
        end
      rescue IO::Error
        # The client went away.
      ensure
        Live.hub.unsubscribe(@subscription)
        Live.closed(@viewer)
      end

      # Whether the viewer may still see the page, asked while no event
      # comes, so that a stream whose session ended does not hold its slot.
      # A failing check keeps the stream, as a failing event does.
      private def allowed? : Bool
        !@turn.call(nil).is_a?(Ended)
      rescue ex
        Log.error(exception: ex) { "live: #{@path} failed checking access" }
        @tracer.try(&.report(ex, "live #{@path}"))
        true
      end

      # Renders and writes *entry* for the viewer; `false` once they may no
      # longer see the page. A bug in `live` or a component skips the
      # event, reported as a failed trace, and the stream goes on.
      private def deliver(io : IO, entry : Entry) : Bool
        answer = begin
          @turn.call(entry.event)
        rescue ex
          Log.error(exception: ex) { "live: #{@path} failed on #{entry.event.class}" }
          @tracer.try(&.report(ex, "live #{@path}"))
          nil
        end

        case answer
        in Ended then false
        in Nil   then true
        in SafeHTML
          write(io, entry, answer)
          true
        end
      end

      private def drain : Nil
        loop do
          select
          when entry = @subscription.channel.receive?
            break unless entry
          else
            break
          end
        end
      end

      # One server-sent event: its ID (the hub's position after it), and
      # the actions, one `data:` line per line.
      private def write(io : IO, entry : Entry?, html : SafeHTML) : Nil
        io << "id: " << Live.hub.position(entry) << '\n' if entry
        # A lone CR ends a line for EventSource too, so it must not reach
        # the stream inside a `data:` line.
        html.value.chomp.split(/\r\n|\r|\n/) { |line| io << "data: " << line << '\n' }
        io << '\n'
        io.flush
      end
    end

    # Turbo's page refresh, sent when a stream cannot tell what changed.
    def self.refresh : SafeHTML
      Punch::TurboStream.new.refresh.render
    end
  end
end
