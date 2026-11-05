require "log"
require "uri"

module Punch::HTTP
  # Requests for paths that only scanners ask for, such as `/wp-login.php`,
  # `/.env.backup`, or `/.git/config` (`docs/http.md`, "Probes and bans").
  # The server answers them before anything else runs: 404 without a body,
  # no trace, no wide event. An address that keeps probing is banned for a
  # while and gets 403 for everything but `/up`.
  #
  # The patterns are Punch's list, which an app changes once in
  # `app/setup.cr`:
  #
  # ```
  # Punch::HTTP::Probes.patterns = Punch::HTTP::Probes::Patterns.default
  #   .with(prefixes: ["/old-admin"])
  #   .without(extensions: [".log"])
  # ```
  #
  # Probes are counted in memory; bans are kept in `cache.db`, which every
  # process reads again every `Settings::POLL`.
  module Probes
    # The bans in `cache.db`, created by `Caches::Durable` with its own
    # tables, outside the cache's layout (like rate limits).
    TABLES = {
      <<-SQL,
        CREATE TABLE IF NOT EXISTS punch_probe_bans (
          address   TEXT    NOT NULL PRIMARY KEY,
          banned_at INTEGER NOT NULL,
          ends_at   INTEGER NOT NULL,
          strikes   INTEGER NOT NULL,
          paths     TEXT    NOT NULL
        ) STRICT, WITHOUT ROWID
        SQL
    }

    # :nodoc:
    # Creates the tables, if missing; for `Caches::Durable`.
    def self.create_tables(db : Writer) : Nil
      TABLES.each { |sql| db.exec(sql) }
    end

    @@patterns = Patterns.default
    @@current : Guard? = nil

    # The patterns servers created from now on use.
    def self.patterns : Patterns
      @@patterns
    end

    def self.patterns=(patterns : Patterns) : Patterns
      @@patterns = patterns
    end

    # The guard of the server this process runs (`serve`), for the ops
    # console.
    def self.current? : Guard?
      @@current
    end

    # :nodoc:
    def self.attach(guard : Guard?) : Nil
      @@current = guard
    end

    # The paths among *paths* (route templates, asset URLs) that *patterns*
    # would answer as probes: the app could not serve them. A path
    # parameter (`:id`) stands for a plain value.
    def self.conflicts(paths : Enumerable(String), patterns : Patterns = self.patterns) : Array(String)
      paths.select do |path|
        concrete = path.split('/').join('/') { |segment| segment.starts_with?(':') ? "x" : segment }
        patterns.match?(concrete)
      end.uniq!.sort!
    end

    # The key a ban is kept under for *text*, an address as people write
    # it (`203.0.113.7`, `2001:db8::1`, `2001:db8:0:1::/64`): IPv4 as it is,
    # IPv6 by its /64, as rate limits count. `nil` if it is no address.
    def self.address_key(text : String) : String?
      text = text.strip.rchop("/64")
      address = TrustedProxies.canonical(text) || return
      RateLimits.ip_key(address)
    end

    # The bans in *database* (`cache.db`), most recent first, the active
    # ones and those whose count is still remembered.
    def self.list(database : Database) : Array(Ban)
      database.read do |db|
        db.query_all(<<-SQL, name: "Punch::HTTP::Probes.list") { |row| Ban.read(row) }
          SELECT address, banned_at, ends_at, strikes, paths FROM punch_probe_bans ORDER BY banned_at DESC, address
          SQL
      end
    end

    # Lifts the ban of *address* (a key from `address_key`) in *database*
    # and forgets its count; true if there was one. Another process
    # notices within `Settings::POLL`.
    def self.lift(database : Database, address : String) : Bool
      database.write do |db|
        db.exec("DELETE FROM punch_probe_bans WHERE address = ?", address, name: "Punch::HTTP::Probes.lift").changes > 0
      end
    end

    # What is a probe: file extensions of the last segment, path prefixes
    # by whole segments, and segments that start with a dot. Nothing under
    # `/.well-known/` is a probe: Apple, Google, browsers, and security
    # researchers fetch it in good faith. Matching ignores ASCII case.
    struct Patterns
      # Files no Punch app serves: scripts of other platforms, backups,
      # dumps, archives, and configuration. Nothing a browser asks for on
      # its own (`/favicon.ico`, `/apple-touch-icon.png`, `/robots.txt`).
      EXTENSIONS = %w[.php .php3 .php4 .php5 .php7 .phtml .phar .asp .aspx .ashx .asmx .axd .jsp .jspx .cgi .pl
        .env .bak .backup .old .orig .save .swp .sql .sqlite .sqlite3 .mdb .tar .tgz .gz .zip .rar .7z
        .ini .conf .cfg .log .pem .key .yml .yaml]

      # Other platforms' admin pages and well-known holes.
      PREFIXES = %w[/wp /wp-admin /wp-content /wp-includes /wp-json /wordpress /cgi-bin /phpmyadmin /pma /myadmin
        /vendor/phpunit /actuator /boaform /hnap1 /_ignition /manager/html]

      WELL_KNOWN = "/.well-known"

      EXTENSION = /\A\.[a-z0-9]+\z/
      PREFIX    = /\A(\/[a-z0-9._~!$&'()*+,;=:@\-]+)+\z/

      getter extensions : Set(String)
      getter prefixes : Array(String)
      # Whether a segment that starts with a dot is a probe (`/.env`,
      # `/.git/config`).
      getter? dot_segments : Bool

      # Raises `ArgumentError` for an extension that is not a dot and
      # letters or digits, and a prefix that is not a path without a
      # trailing slash.
      def initialize(extensions : Enumerable(String), prefixes : Enumerable(String), *, @dot_segments : Bool = true)
        @extensions = extensions.map { |extension| Patterns.extension(extension) }.to_set
        @prefixes = prefixes.map { |prefix| Patterns.prefix(prefix) }.uniq!
      end

      # Punch's list.
      def self.default : self
        new(EXTENSIONS, PREFIXES)
      end

      # Nothing is a probe.
      def self.none : self
        new([] of String, [] of String, dot_segments: false)
      end

      # These patterns and *extensions* and *prefixes*.
      def with(*, extensions : Enumerable(String) = [] of String, prefixes : Enumerable(String) = [] of String) : self
        Patterns.new(@extensions.to_a + extensions.to_a, @prefixes + prefixes.to_a, dot_segments: @dot_segments)
      end

      # These patterns without *extensions* and *prefixes*, and without the
      # rule for dot segments when *dot_segments* is true. Raises
      # `ArgumentError` for an entry that is not there, so a typo does not
      # go unnoticed.
      def without(*, extensions : Enumerable(String) = [] of String, prefixes : Enumerable(String) = [] of String,
                  dot_segments : Bool = false) : self
        removed_extensions = extensions.map { |extension| Patterns.extension(extension) }
        removed_prefixes = prefixes.map { |prefix| Patterns.prefix(prefix) }
        removed_extensions.each { |extension| raise ArgumentError.new("probe extension #{extension} is not in the list") unless @extensions.includes?(extension) }
        removed_prefixes.each { |prefix| raise ArgumentError.new("probe prefix #{prefix} is not in the list") unless @prefixes.includes?(prefix) }
        Patterns.new(@extensions.to_a - removed_extensions, @prefixes - removed_prefixes, dot_segments: @dot_segments && !dot_segments)
      end

      # Whether a request for *path* is a probe; a percent-encoded path
      # also as decoded.
      def match?(path : String) : Bool
        return false unless path.starts_with?('/')
        return true if test?(path)

        path.includes?('%') && test?(URI.decode(path))
      end

      private def test?(path : String) : Bool
        return false if Patterns.below?(path, WELL_KNOWN)

        (@dot_segments && path.includes?("/.")) || extension?(path) || @prefixes.any? { |prefix| Patterns.below?(path, prefix) }
      end

      private def extension?(path : String) : Bool
        return false if @extensions.empty?

        dot = path.rindex('.') || return false
        # A dot in an earlier segment.
        return false if path.index('/', dot)

        @extensions.includes?(path[dot..].downcase)
      end

      # Whether *path* is *prefix* (lowercase) or below it, ignoring ASCII
      # case.
      protected def self.below?(path : String, prefix : String) : Bool
        return false if path.bytesize < prefix.bytesize

        bytes = path.to_slice
        prefix.to_slice.each_with_index do |byte, index|
          found = bytes[index]
          found += 32 if 'A'.ord <= found <= 'Z'.ord
          return false unless found == byte
        end
        path.bytesize == prefix.bytesize || bytes[prefix.bytesize] == '/'.ord
      end

      protected def self.extension(text : String) : String
        extension = text.downcase
        raise ArgumentError.new("probe extension #{text.inspect} must be a dot and letters or digits, such as .php") unless EXTENSION.matches?(extension)
        extension
      end

      protected def self.prefix(text : String) : String
        prefix = text.downcase
        if !PREFIX.matches?(prefix) || below?(prefix, WELL_KNOWN)
          raise ArgumentError.new("probe prefix #{text.inspect} must be a path without a trailing slash, such as /wp-admin, and not below /.well-known")
        end
        prefix
      end
    end

    # How probes are answered and bans made (`PUNCH_PROBES`,
    # `PUNCH_PROBE_*`, `Punch::AppConfig`).
    struct Settings
      # How long after its last ban ended an address's count is remembered.
      FORGET = 7.days
      # How often a process reads the bans in `cache.db`.
      POLL = 30.seconds

      getter? enabled : Bool
      # Probes from one address within `window` that ban it; 0 never bans.
      getter ban_after : Int32
      getter window : Time::Span
      # How long the first, the second, … ban lasts; the last applies to
      # every further one.
      getter bans : Array(Time::Span)
      # Addresses never banned.
      getter allow : TrustedProxies

      def initialize(*, @enabled = true, @ban_after = 2, @window = 10.minutes, @bans = [1.hour, 24.hours, 7.days],
                     @allow = TrustedProxies.none)
        raise ArgumentError.new("ban_after must not be negative") if ban_after < 0
        raise ArgumentError.new("window must be positive") unless window.positive?
        raise ArgumentError.new("bans must name at least one positive duration") if bans.empty? || !bans.all?(&.positive?)
      end

      # How long the *strikes*-th ban of an address lasts.
      def duration(strikes : Int32) : Time::Span
        @bans[{strikes, @bans.size}.min - 1]
      end
    end

    # A ban: the address (IPv6 by its /64), when it began and ends, the
    # how-manyth it is, and the first paths the address asked for.
    struct Ban
      include JSON::Serializable

      getter address : String
      @[JSON::Field(converter: Time::EpochMillisConverter)]
      getter banned_at : Time
      @[JSON::Field(converter: Time::EpochMillisConverter)]
      getter ends_at : Time
      getter strikes : Int32
      getter paths : Array(String)

      def initialize(@address : String, @banned_at : Time, @ends_at : Time, @strikes : Int32, @paths : Array(String))
      end

      def active?(now : Time) : Bool
        ends_at > now
      end

      # :nodoc:
      def self.read(row) : self
        new(row.read(String), Time.unix_ms(row.read(Int64)), Time.unix_ms(row.read(Int64)), row.read(Int32),
          Array(String).from_json(row.read(String)))
      end
    end

    # Answers probes and banned addresses for one server, counts probes per
    # address, and bans. Thread safe: a request reads the active bans
    # without a lock, from a table replaced whole when it changes.
    class Guard
      Log = ::Log.for("punch.http.probes")

      # Paths kept per address for its ban, and the characters of each.
      MAX_PATHS  =   3
      PATH_CHARS = 100

      # Never banned, whatever the settings say.
      LOOPBACK = TrustedProxies.parse(["127.0.0.0/8", "::1"])

      # Private, shared, and link-local networks. Such an address is
      # banned only when it came through a trusted proxy: otherwise it is
      # most likely a proxy that was not configured, or Docker's port
      # forwarding, and every client would be banned with it.
      PRIVATE = TrustedProxies.parse(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
                                      "169.254.0.0/16", "0.0.0.0/8", "fc00::/8", "fd00::/8", "fe80::/10"])

      # The active bans as requests read them: address to end, in Unix
      # milliseconds.
      private class Active
        getter ends : Hash(String, Int64)

        def initialize(@ends : Hash(String, Int64) = {} of String => Int64)
        end
      end

      getter settings : Settings
      getter patterns : Patterns
      # Requests answered as probes, refused as banned, and bans made, by
      # this guard.
      getter probes = Atomic(Int64).new(0)
      getter refused = Atomic(Int64).new(0)
      getter bans_made = Atomic(Int64).new(0)

      @active = Atomic(Active).new(Active.new)
      @lock = Mutex.new
      # Every ban this process knows, active or remembered, by address.
      @known = {} of String => Ban
      # Bans made here and not yet written to `cache.db`.
      @pending = [] of Ban
      @hits = Hits.new
      @database : Database?
      @wake = Channel(Bool).new(1)
      @done = Channel(Nil).new

      def initialize(@settings : Settings, @patterns : Patterns, @proxies : TrustedProxies)
      end

      # The answer for a probe or a banned address, or `nil` when the
      # request goes on. `/up` always goes on.
      def check(request : ::HTTP::Request, peer : String) : Response?
        return unless @settings.enabled?

        path = request.path
        return if path == Server::HEALTH_PATH

        ends = @active.get.ends
        unless ends.empty?
          client, _ = Context.client(request.headers, peer, @proxies)
          if (end_ms = ends[RateLimits.ip_key(client)]?) && end_ms > Time.utc.to_unix_ms
            @refused.add(1, :relaxed)
            return answer(:forbidden)
          end
        end
        return unless @patterns.match?(path)

        @probes.add(1, :relaxed)
        if @settings.ban_after > 0
          client, forwarded = Context.client(request.headers, peer, @proxies)
          hit(client, path) if bannable?(client, forwarded)
        end
        answer(:not_found)
      end

      # Whether *client* may be banned: never loopback, a trusted proxy, or
      # an allowed address, and a private address only when it came
      # through a trusted proxy.
      def bannable?(client : String, forwarded : Bool) : Bool
        return false unless TrustedProxies.canonical(client)
        return false if LOOPBACK.includes?(client) || @proxies.includes?(client) || @settings.allow.includes?(client)

        forwarded || !PRIVATE.includes?(client)
      end

      # Every ban this process knows: from `cache.db` when attached, so
      # also those of the other process, else its own.
      def list : Array(Ban)
        if database = @database
          Probes.list(database)
        else
          @lock.synchronize { @known.values.sort_by! { |ban| {-ban.banned_at.to_unix_ms, ban.address} } }
        end
      end

      # Lifts the ban of *address* (a key from `Probes.address_key`) here
      # and in `cache.db`, and forgets its count; true if there was one.
      def lift(address : String) : Bool
        known = @lock.synchronize do
          @pending.reject!(&.address.==(address))
          removed = @known.delete(address)
          publish
          !removed.nil?
        end
        stored = @database.try { |database| Probes.lift(database, address) } || false
        known || stored
      end

      # Keeps bans in *database* (`cache.db`) from now on, reads them now,
      # and every `Settings::POLL` again in a fiber of its own, until
      # `stop`.
      def start(database : Database) : Nil
        @database = database
        refresh
        spawn(name: "punch.probes") { run }
      end

      # Writes the bans not yet in `cache.db` and stops reading it.
      def stop : Nil
        return unless @database

        @wake.close
        @done.receive?
      end

      # Counters and the active bans in *registry* (`docs/metrics.md`).
      def observe(registry : Metrics::Registry = Metrics.registry) : Nil
        registry.observe("punch.http.probes", :counter, "{request}", "Requests for paths only scanners ask for, answered 404 without a trace") do |recorder|
          recorder.record(@probes.get, Metrics::Attributes.new)
        end
        registry.observe("punch.http.refused", :counter, "{request}", "Requests from banned addresses, answered 403 without a trace") do |recorder|
          recorder.record(@refused.get, Metrics::Attributes.new)
        end
        registry.observe("punch.http.bans", :counter, "{ban}", "Addresses this process banned") do |recorder|
          recorder.record(@bans_made.get, Metrics::Attributes.new)
        end
        registry.observe("punch.http.banned", :gauge, "{address}", "Addresses banned now") do |recorder|
          at = Time.utc.to_unix_ms
          recorder.record(@active.get.ends.count { |_, end_ms| end_ms > at }, Metrics::Attributes.new)
        end
      end

      # An answer without a body: the security headers, and the connection
      # closes after it.
      private def answer(status : ::HTTP::Status) : Response
        security = @answer_headers ||= begin
          headers = ::HTTP::Headers.new
          SecurityHeaders::DEFAULTS.each { |name, value| headers[name] = value }
          headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
          headers["Connection"] = "close"
          headers
        end
        Response.new(status, "", security.dup)
      end

      @answer_headers : ::HTTP::Headers?

      private def hit(client : String, path : String) : Nil
        address = RateLimits.ip_key(client)
        at = Time.utc
        paths = @hits.hit(address, at, @settings.window, @settings.ban_after, shown(path)) || return
        ban(address, paths, at)
      end

      private def ban(address : String, paths : Array(String), at : Time) : Nil
        ban = @lock.synchronize do
          previous = @known[address]?
          strikes = previous && previous.ends_at + Settings::FORGET > at ? previous.strikes + 1 : 1
          made = Ban.new(address, at, at + @settings.duration(strikes), strikes, paths)
          @known[address] = made
          @pending << made if @database
          publish
          made
        end
        @bans_made.add(1, :relaxed)
        Log.info &.emit("address banned", address: address, ban: ban.strikes, until: ban.ends_at.to_rfc3339, paths: paths.join(" "))
        wake if @database
      end

      # Asks the fiber to write at once; it does so at its next poll anyway.
      private def wake : Nil
        select
        when @wake.send(true)
        else
        end
      rescue Channel::ClosedError
        # Stopping: the last write runs without being asked.
      end

      # The active bans from what is known, for requests to read. Under
      # `@lock`.
      private def publish : Nil
        at = Time.utc
        ends = {} of String => Int64
        @known.each_value { |ban| ends[ban.address] = ban.ends_at.to_unix_ms if ban.active?(at) }
        @active.set(Active.new(ends))
      end

      # The path as a log line and the console show it: at most
      # `PATH_CHARS` characters, anything but visible ASCII escaped.
      private def shown(path : String) : String
        String.build do |io|
          path.each_byte.first(PATH_CHARS).each do |byte|
            if 0x21 <= byte <= 0x7e
              io << byte.unsafe_chr
            else
              io << '%' << byte.to_s(16, upcase: true).rjust(2, '0')
            end
          end
        end
      end

      private def run : Nil
        loop do
          open = select
          when woken = @wake.receive?
            woken
          when timeout(Settings::POLL)
            true
          end
          flush
          break if open.nil?

          refresh
        end
      ensure
        @done.close
      end

      # Writes the pending bans; a ban for an address already in the file
      # keeps the later end and the higher count.
      private def flush : Nil
        database = @database || return
        bans = @lock.synchronize { @pending.dup.tap { @pending.clear } }
        return if bans.empty?

        database.write do |db|
          bans.each do |ban|
            db.exec(<<-SQL, ban.address, ban.banned_at.to_unix_ms, ban.ends_at.to_unix_ms, ban.strikes, ban.paths.to_json, name: "Punch::HTTP::Probes.flush")
              INSERT INTO punch_probe_bans (address, banned_at, ends_at, strikes, paths) VALUES (?, ?, ?, ?, ?)
              ON CONFLICT (address) DO UPDATE SET banned_at = excluded.banned_at, ends_at = max(ends_at, excluded.ends_at),
                strikes = max(strikes, excluded.strikes), paths = excluded.paths
              SQL
          end
        end
      rescue ex : Database::Error
        Log.error(exception: ex) { "could not write #{bans.try(&.size)} ban(s) to cache.db; they hold in this process only" }
      end

      # Reads every ban from `cache.db`, after removing those whose count
      # is forgotten; bans made here since stay.
      private def refresh : Nil
        database = @database || return
        at = Time.utc
        database.write do |db|
          db.exec("DELETE FROM punch_probe_bans WHERE ends_at <= ?", (at - Settings::FORGET).to_unix_ms, name: "Punch::HTTP::Probes.refresh")
        end
        bans = Probes.list(database)
        @lock.synchronize do
          @known = bans.to_h { |ban| {ban.address, ban} }
          @pending.each { |ban| @known[ban.address] = ban }
          publish
        end
      rescue ex : Database::Error
        Log.error(exception: ex) { "could not read the bans in cache.db" }
      end

      # Probes per address within the window, in this process, in shards
      # so threads rarely wait for each other. Bounded: a full shard drops
      # the entries whose window has passed, then the older half.
      private class Hits
        SHARDS   =      16
        MAX_KEYS = 100_000

        record Entry, first : Time, count : Int32, paths : Array(String)

        @shards : Array({Mutex, Hash(String, Entry)})

        def initialize
          @shards = Array.new(SHARDS) { {Mutex.new, {} of String => Entry} }
        end

        # Counts a probe of *path* from *address*; the paths it asked for
        # when this one makes *after* within *window*, and the count starts
        # over.
        def hit(address : String, at : Time, window : Time::Span, after : Int32, path : String) : Array(String)?
          lock, entries = @shards[(address.hash % SHARDS).to_i]
          lock.synchronize do
            entry = entries[address]?
            entry = nil if entry && at - entry.first > window
            paths = entry.try(&.paths.dup) || [] of String
            paths << path if paths.size < MAX_PATHS
            count = (entry.try(&.count) || 0) + 1
            if count >= after
              entries.delete(address)
              return paths
            end

            make_room(entries, at, window) if entry.nil? && entries.size >= MAX_KEYS // SHARDS
            entries[address] = Entry.new(entry.try(&.first) || at, count, paths)
            nil
          end
        end

        private def make_room(entries : Hash(String, Entry), at : Time, window : Time::Span) : Nil
          entries.reject! { |_, entry| at - entry.first > window }
          return if entries.size < MAX_KEYS // SHARDS

          entries.to_a.sort_by!(&.[1].first).first(entries.size // 2).each { |address, _| entries.delete(address) }
        end
      end
    end
  end
end
