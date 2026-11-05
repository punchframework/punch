module Punch
  # Limits how often an operation runs for one key. Several per operation,
  # each with its own name:
  #
  # ```
  # @[Punch::RateLimit(5, per: 1.minute, by: :ip)]
  # @[Punch::RateLimit(20, per: 1.hour, by: :email, name: "sign_in_email", store: :durable)]
  # struct SignIn < Punch::Command
  # ```
  #
  # *by* is `:ip` (the client address; an IPv6 address counts by its /64),
  # `:actor` (the signed-in user), `:token` (the API token, when the
  # request came with one), `:challenge` (the user whose sign-in waits for
  # a second factor, for Commands taking `Punch::Auth::SecondFactorCheck`), or a
  # field of the input (`:email`). `:ip` limits run before the body is
  # read, field and `:challenge` limits after the input parsed, and
  # `:actor` and `:token` limits after authentication, inside the
  # transaction. *store* is `:memory` (per process, the default) or
  # `:durable` (`cache.db`: survives restarts, shared by two processes; for
  # sign-in, sign-up, password reset, token creation). *name* defaults to
  # the operation and *by*, such as `accounts.sign_in.ip`.
  #
  # A refused request gets 429 with `Retry-After`; every request to a
  # limited operation gets `RateLimit-Policy` and `RateLimit` headers.
  annotation RateLimit
  end

  # Marks an operation that is deliberately not rate-limited, with the
  # reason: `@[Punch::RateLimitExempt("signed webhook; the provider retries")]`.
  # `punch check` requires a limit or this on every Command that does not
  # need a signed-in user.
  annotation RateLimitExempt
  end

  # A request refused by a rate limit: 429, `Retry-After`, and the limit's
  # name.
  @[Punch::Status(429)]
  struct RateLimited
    include JSON::Serializable

    # Seconds until the next request can succeed.
    getter retry_after : Int32
    # The name of the limit that refused it.
    getter limit : String

    def initialize(@retry_after : Int32, @limit : String)
    end
  end

  # A rate limit by the generic cell rate algorithm (GCRA): per key one
  # "theoretical arrival time", which each allowed request moves by
  # *period* / *limit*. A key may run *limit* times at once and then once
  # per *period* / *limit*; there is no burst at a window's edge. Thread
  # safe; usable on its own in jobs and for outbound calls:
  #
  # ```
  # GEOCODER = Punch::RateLimits::Limiter.new("geocoder", 10, per: 1.second)
  # case result = GEOCODER.check("global")
  # in Punch::RateLimits::Limiter::Allowed then call_geocoder
  # in Punch::RateLimits::Limiter::Limited then retry_in(result.retry_after)
  # end
  # ```
  #
  # Names are unique in a process.
  class RateLimits::Limiter
    enum Store
      # In this process, bounded by key count; lost on restart.
      Memory
      # In `cache.db`: one small write per check.
      Durable
    end

    # *remaining* requests now; the key is back to its full *limit* after
    # *reset*.
    record Allowed, remaining : Int32, reset : Time::Span
    # The next request can succeed after *retry_after*.
    record Limited, retry_after : Time::Span

    NAME = /\A[a-z0-9][a-z0-9_.:\-]*\z/

    getter name : String
    getter limit : Int32
    getter period : Time::Span
    getter store : Store
    # What the key is, for reports: `ip`, `actor`, `token`, a field name.
    getter by : String
    # Allowed and limited checks in this process.
    getter allowed = Atomic(Int64).new(0)
    getter limited = Atomic(Int64).new(0)

    @interval : Int64
    @window : Int64
    @memory : RateLimits::Memory?
    @durable_checks = Atomic(Int64).new(0)

    def initialize(@name : String, @limit : Int32, *, per @period : Time::Span, @store : Store = Store::Memory, @by : String = "key",
                   max_keys : Int32 = RateLimits::Memory::MAX_KEYS)
      raise ArgumentError.new("rate limit name must be lowercase letters, digits, and _ . : -, got #{name.inspect}") unless NAME.matches?(name)
      raise ArgumentError.new("rate limit #{name}: limit must be positive") unless limit > 0
      raise ArgumentError.new("rate limit #{name}: period must be positive") unless period.positive?
      @window = period.total_nanoseconds.to_i64
      @interval = Math.max(@window // limit, 1_i64)
      @memory = RateLimits::Memory.new(max_keys) if store.memory?
      RateLimits.register(self)
    end

    # Counts a request for *key* if the limit allows it.
    def check(key : String, now : Time = Time.utc) : Allowed | Limited
      result = case memory = @memory
               in RateLimits::Memory then memory.update(key, now_ns(now)) { |stored, instant| gcra(stored, instant) }
               in Nil                then durable_check(key, now)
               end
      (result.is_a?(Allowed) ? @allowed : @limited).add(1, :relaxed)
      result
    end

    # Forgets *key*, or every key, so it starts with its full limit. A
    # durable limit uses *database*, by default the attached `cache.db`.
    def reset(key : String? = nil, *, database : Database? = nil) : Nil
      if memory = @memory
        memory.reset(key)
      else
        (database || RateLimits.database).write do |db|
          if key
            db.exec("DELETE FROM punch_rate_limits WHERE limiter = ? AND key = ?", @name, key, name: "Punch::RateLimits::Limiter.reset")
          else
            db.exec("DELETE FROM punch_rate_limits WHERE limiter = ?", @name, name: "Punch::RateLimits::Limiter.reset")
          end
        end
      end
    end

    # Keys tracked now: limited or still recovering.
    def keys(now : Time = Time.utc, *, database : Database? = nil) : Int64
      if memory = @memory
        memory.size(now_ns(now))
      else
        (database || RateLimits.database).read do |db|
          db.query_one?("SELECT count(*) FROM punch_rate_limits WHERE limiter = ? AND tat > ?", @name, now_ns(now), &.read(Int64)) || 0_i64
        end
      end
    end

    # The limit as an item of the `RateLimit-Policy` header:
    # `"name";q=5;w=60`.
    def policy : String
      %("#{@name}";q=#{@limit};w=#{Math.max(@period.total_seconds.ceil.to_i64, 1_i64)})
    end

    # `5 per 1m by ip`, for reports and the OpenAPI document.
    def to_s(io : IO) : Nil
      io << @name << ": " << @limit << " per " << RateLimits.span_text(@period) << " by " << @by
      io << " (durable)" if @store.durable?
    end

    # GCRA at *now* (ns) for a key whose stored arrival time is *stored*:
    # the new arrival time to store, or `nil` when limited.
    protected def gcra(stored : Int64?, now : Int64) : {Int64?, Allowed | Limited}
      tat = Math.max(stored || now, now) + @interval
      ahead = tat - now
      if ahead > @window
        {nil, Limited.new((ahead - @window).nanoseconds)}
      else
        {tat, Allowed.new(((@window - ahead) // @interval).to_i32, ahead.nanoseconds)}
      end
    end

    private def durable_check(key : String, now : Time) : Allowed | Limited
      at = now_ns(now)
      purge = @durable_checks.add(1, :relaxed) % RateLimits::PURGE_EVERY == 0
      RateLimits.database.write do |db|
        stored = db.query_one?("SELECT tat FROM punch_rate_limits WHERE limiter = ? AND key = ?", @name, key,
          name: "Punch::RateLimits::Limiter.check", &.read(Int64))
        tat, result = gcra(stored, at)
        if tat
          db.exec(<<-SQL, @name, key, tat, name: "Punch::RateLimits::Limiter.check")
            INSERT INTO punch_rate_limits (limiter, key, tat) VALUES (?, ?, ?)
            ON CONFLICT (limiter, key) DO UPDATE SET tat = excluded.tat
            SQL
        end
        RateLimits.purge(db, at) if purge
        result
      end
    end

    private def now_ns(now : Time) : Int64
      now.to_unix_ns.to_i64
    end
  end

  # The rate limiters of one process: the registry, the clock, the durable
  # table in `cache.db`, and what the endpoints call.
  module RateLimits
    # Durable checks between two purges of expired keys.
    PURGE_EVERY = 1024

    @@limiters = [] of RateLimits::Limiter
    @@lock = Mutex.new

    # The table in `cache.db`, created by `Caches::Durable` with its own.
    TABLES = {
      <<-SQL,
        CREATE TABLE IF NOT EXISTS punch_rate_limits (
          limiter TEXT    NOT NULL,
          key     TEXT    NOT NULL,
          tat     INTEGER NOT NULL,
          PRIMARY KEY (limiter, key)
        ) STRICT, WITHOUT ROWID
        SQL
      "CREATE INDEX IF NOT EXISTS punch_rate_limits_by_tat ON punch_rate_limits (tat)",
    }

    # :nodoc:
    # Creates the tables, if missing; for `Caches::Durable`.
    def self.create_tables(db : Writer) : Nil
      TABLES.each { |sql| db.exec(sql) }
    end

    # :nodoc:
    def self.register(limiter : RateLimits::Limiter) : Nil
      @@lock.synchronize do
        if @@limiters.any?(&.name.==(limiter.name))
          raise ArgumentError.new("two rate limits are named #{limiter.name}; give one `name:`")
        end
        @@limiters << limiter
      end
    end

    # Every limiter created so far. Operation limits are created with the
    # route table.
    def self.limiters : Array(RateLimits::Limiter)
      @@lock.synchronize { @@limiters.dup }
    end

    def self.find(name : String) : RateLimits::Limiter?
      limiters.find(&.name.==(name))
    end

    # `cache.db`, attached by `serve` (and `punch/spec`). Durable limits
    # need it; without it they raise rather than let everything through.
    def self.database : Database
      Caches.durable.try(&.database) || raise Database::Error.new("a durable rate limit needs cache.db, which is not attached (Punch::Caches.attach)")
    end

    # Removes keys that are back to their full limit.
    def self.purge(db : Writer, now : Int64) : Int64
      db.exec(<<-SQL, now, name: "Punch::RateLimits.purge").changes
        DELETE FROM punch_rate_limits WHERE (limiter, key) IN (
          SELECT limiter, key FROM punch_rate_limits WHERE tat <= ? LIMIT 10000
        )
        SQL
    end

    # Forgets every key of every limiter, and the counts: for specs.
    def self.reset : Nil
      limiters.each do |limiter|
        limiter.allowed.set(0)
        limiter.limited.set(0)
        limiter.reset if limiter.store.memory?
      end
      if durable = Caches.durable
        durable.database.write(&.exec("DELETE FROM punch_rate_limits"))
      end
    end

    # The key of a client address: IPv4 as it is, IPv6 by its /64, since
    # one client usually holds the whole prefix.
    def self.ip_key(ip : String) : String
      return ip unless ip.includes?(':')

      address = ip.split('%', 2).first
      mapped = address.downcase
      return mapped.lchop("::ffff:") if mapped.starts_with?("::ffff:") && mapped.includes?('.')

      head, _, tail = address.partition("::")
      first = head.empty? ? [] of String : head.split(':')
      last = tail.empty? ? [] of String : tail.split(':')
      groups = address.includes?("::") ? first + Array.new(Math.max(8 - first.size - last.size, 0), "0") + last : first
      groups[0, 4].join(':') { |group| group.to_i?(16).try(&.to_s(16)) || group.downcase } + "::/64"
    end

    # A key from an input field: its text, or `nil` (no limit) when absent.
    def self.key(value) : String?
      value.nil? ? nil : value.to_s
    end

    # `1m`, `1h`, `30s`, `2d`.
    def self.span_text(span : Time::Span) : String
      seconds = span.total_seconds
      {86400 => "d", 3600 => "h", 60 => "m"}.each do |size, unit|
        return "#{(seconds / size).to_i}#{unit}" if seconds >= size && seconds % size == 0
      end
      seconds == seconds.to_i ? "#{seconds.to_i}s" : "#{seconds}s"
    end

    # The rate-limit state of one request: the policies checked, the
    # tightest allowance, and a refusal.
    # :nodoc:
    class State
      getter policies = [] of String
      property remaining : {String, Int32, Time::Span}? = nil
      property retry_after : Time::Span? = nil
    end

    # Checks *limiter* for *key* within a request; `nil` when allowed or
    # when there is no key. Records the headers to send.
    def self.limited(limiter : RateLimits::Limiter, key : String?, context : HTTP::Context) : RateLimited?
      return unless key

      state = context.rate_limits ||= State.new
      state.policies << limiter.policy

      case result = limiter.check(key)
      in RateLimits::Limiter::Allowed
        tightest = state.remaining
        state.remaining = {limiter.name, result.remaining, result.reset} if tightest.nil? || result.remaining < tightest[1]
        nil
      in RateLimits::Limiter::Limited
        state.remaining = {limiter.name, 0, result.retry_after}
        state.retry_after = result.retry_after
        span = context.span
        span.set("punch.rate_limit", limiter.name)
        span.set("punch.outcome", "rate_limited")
        RateLimited.new(Math.max(result.retry_after.total_seconds.ceil.to_i, 1), limiter.name)
      end
    end

    # A refusal before the operation ran: a page for clients that prefer
    # HTML, Problem Details otherwise.
    def self.respond(limited : RateLimited, context : HTTP::Context) : HTTP::Response
      params = {"retry_after" => limited.retry_after.to_i64, "limit" => limited.limit} of String => Invalid::Param
      response = if HTTP::Accept.preferred(context.request.headers["Accept"]?, Routing::Router::OFFERS) == "text/html"
                   Pages.problem(:too_many_requests, "rate_limited", context, params: params)
                 else
                   HTTP::Response.problem(:too_many_requests, context, "rate_limited", params) do |json|
                     json.field "retry_after", limited.retry_after
                     json.field "limit", limited.limit
                   end
                 end
      HTTP::Accept.vary(response)
    end

    # Adds `RateLimit-Policy`, `RateLimit`, and on a refusal `Retry-After`
    # (draft-ietf-httpapi-ratelimit-headers).
    def self.apply(response : HTTP::Response, context : HTTP::Context) : HTTP::Response
      state = context.rate_limits || return response
      headers = response.headers
      headers["RateLimit-Policy"] = state.policies.join(", ")
      if remaining = state.remaining
        name, left, reset = remaining
        headers["RateLimit"] = %("#{name}";r=#{left};t=#{Math.max(reset.total_seconds.ceil.to_i, 0)})
      end
      if retry = state.retry_after
        headers["Retry-After"] = Math.max(retry.total_seconds.ceil.to_i, 1).to_s
      end
      response
    end

    # Keys and their arrival times in this process, in shards so threads
    # rarely wait for each other. Bounded: a full shard drops the keys that
    # have recovered, then the half closest to recovery.
    # :nodoc:
    class Memory
      SHARDS   =      16
      MAX_KEYS = 100_000

      @shards : Array({Mutex, Hash(String, Int64)})
      @per_shard : Int32

      def initialize(max_keys : Int32)
        @per_shard = Math.max(max_keys // SHARDS, 1)
        @shards = Array.new(SHARDS) { {Mutex.new, {} of String => Int64} }
      end

      def update(key : String, now : Int64, & : Int64?, Int64 -> {Int64?, RateLimits::Limiter::Allowed | RateLimits::Limiter::Limited}) : RateLimits::Limiter::Allowed | RateLimits::Limiter::Limited
        lock, keys = @shards[(key.hash % SHARDS).to_i]
        lock.synchronize do
          tat, result = yield keys[key]?, now
          if tat
            make_room(keys, now) if keys.size >= @per_shard && !keys.has_key?(key)
            keys[key] = tat
          end
          result
        end
      end

      def reset(key : String?) : Nil
        @shards.each do |lock, keys|
          lock.synchronize { key ? keys.delete(key) : keys.clear }
        end
      end

      def size(now : Int64) : Int64
        @shards.sum { |lock, keys| lock.synchronize { keys.count { |_, tat| tat > now }.to_i64 } }
      end

      private def make_room(keys : Hash(String, Int64), now : Int64) : Nil
        keys.reject! { |_, tat| tat <= now }
        return if keys.size < @per_shard

        keys.to_a.sort_by!(&.[1]).first(keys.size // 2).each { |key, _| keys.delete(key) }
      end
    end
  end
end
