require "digest/sha256"
require "./cache/stats"
require "./cache/durable"
require "./cache/trim"

module Punch
  # The caches of one process: the registry of every `Punch::Cache` created
  # so far, the durable tier they share (`cache.db`), and the switch that
  # turns caching off.
  #
  # `serve` attaches `cache.db` from `PUNCH_STORAGE` and sets `enabled`
  # from `PUNCH_CACHE`; `punch/spec` attaches an in-memory file and empties
  # every store before each example.
  module Caches
    Log = ::Log.for("punch.cache")

    # Where a store keeps its entries.
    enum Tier
      # In this process only: bounded by entry count, fastest, lost on
      # restart.
      Memory
      # In `cache.db`: survives restarts, shared by two processes.
      Durable
      # Memory in front of `cache.db`.
      Both
    end

    # What the registry and the commands know about any store.
    abstract class Store
      abstract def name : String
      abstract def tier : Tier
      abstract def ttl : Time::Span
      abstract def shape : String
      abstract def stats : Stats

      # Removes every entry: from memory, and this store's from the file.
      abstract def clear : Nil

      # Removes the entries in this process's memory only.
      abstract def clear_memory : Nil

      # The entries in this process's memory, expired ones included until
      # trimmed.
      abstract def size : Int32

      # Removes the entries in this process's memory that expired by *now*;
      # returns how many.
      abstract def trim_memory(now : Time) : Int32
    end

    @@stores = [] of Store
    @@lock = Mutex.new
    @@durable : Durable? = nil
    @@enabled = Atomic(Bool).new(true)
    @@epoch = Atomic(Int64).new(0_i64)

    # Makes *durable* the file of every store that has none of its own.
    def self.attach(durable : Durable) : Nil
      @@lock.synchronize { @@durable = durable }
    end

    def self.detach : Nil
      @@lock.synchronize { @@durable = nil }
    end

    def self.durable : Durable?
      @@lock.synchronize { @@durable }
    end

    # Whether stores keep anything. Off (`PUNCH_CACHE=off`), every fetch
    # computes: the app must be correct with an empty cache, and CI runs
    # the specs once that way.
    def self.enabled? : Bool
      @@enabled.get(:relaxed)
    end

    def self.enabled=(value : Bool) : Bool
      @@enabled.set(value)
      value
    end

    # A counter every invalidation (`delete`, `clear`) moves on. A read
    # transaction remembers it at its start (`Database#read`), a fetch
    # outside one at the fetch's start. A value computed from a reading
    # that began before its key was invalidated is returned but not
    # stored: it may come from a snapshot older than the change.
    def self.epoch : Int64
      @@epoch.get
    end

    # :nodoc:
    def self.invalidated : Int64
      @@epoch.add(1) + 1
    end

    # Where the reading a computation sees began: the read transaction
    # the fiber is in, or now.
    # :nodoc:
    def self.reading_since : Int64
      Fiber.current.punch_read_epoch || epoch
    end

    # :nodoc:
    def self.register(store : Store) : Nil
      @@lock.synchronize { @@stores << store }
    end

    # Every store created in this process so far. Stores are constants,
    # which Crystal creates on first use, so one that was never touched is
    # not listed yet.
    def self.stores : Array(Store)
      @@lock.synchronize { @@stores.dup }
    end

    # Empties every store's memory and the attached file.
    def self.clear : Nil
      stores.each(&.clear_memory)
      durable.try(&.clear)
    end

    # The shape of a store: a fingerprint of its key type and its value's
    # JSON Schema (`Punch::JSONSchema`). A binary whose value type changed
    # has another shape, so it never reads entries an older binary wrote;
    # it sees misses.
    def self.shape(key : K.class, value : V.class) : String forall K, V
      schema = JSONSchema.of(V).to_json
      Digest::SHA256.hexdigest("#{K}\n#{schema}")[0, 16]
    end

    # The text of a key in the file and in memory: its stored JSON
    # (`Punch::Stored.json`), which is unambiguous for tuples too.
    def self.key_text(key) : String
      Stored.json(key)
    end

    # Keys are what identifies a record or a question: strings, integers,
    # booleans, enums, domain primitives (typed IDs included), and tuples
    # of those. Checked when a store is declared.
    def self.check_key(type : T.class) : Nil forall T
      {% if T < Tuple %}
        {% for member in T.type_vars %}
          typeof(check_key({{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}))
        {% end %}
      {% elsif T.union? %}
        {% raise "Punch::Cache key #{T} is a union; use one type, or a tuple of several." %}
      {% elsif T.name(generic_args: false) == "Punch::Secret" %}
        {% raise "Punch::Cache key #{T}: a secret cannot be a cache key." %}
      {% elsif T == String || T == Int32 || T == Int64 || T == Bool || T < Enum || T.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
      {% else %}
        {% raise "Punch::Cache key #{T}: keys are String, Int32, Int64, Bool, an enum, a domain primitive, or a tuple of those." %}
      {% end %}
    end

    # A value must not hold a `Punch::Secret` anywhere: a decrypted column
    # would end up in an unencrypted file. Walks the type's fields and type
    # arguments at compile time; nothing runs.
    def self.check_value(type : T.class) : Nil forall T
      {% if T.union? %}
        {% for member in T.union_types %}
          typeof(check_value({{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}))
        {% end %}
      {% elsif T.name(generic_args: false) == "Punch::Secret" %}
        {% raise "Punch::Cache value holds #{T}: secrets cannot be cached, or a decrypted value would end up in an unencrypted file (lib/punch/docs/cache.md)." %}
      {% elsif T < Number || T == String || T == Bool || T == Nil || T == Time || T < Enum || T == Pointer(UInt8) %}
      {% else %}
        {% for argument in T.type_vars %}
          typeof(check_value({{ argument.stringify.gsub(::Punch::NAME_STARTS, "::").id }}))
        {% end %}
        {% for ivar in T.instance_vars %}
          typeof(check_value({{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}))
        {% end %}
      {% end %}
    end

    # Forgets what an event made stale: the `call` Punch writes for a
    # subscriber annotated `@[Punch::Subscriber::Forget(STORE, key: getter)]`. The
    # getter returns a key of the store, a nilable one (nil forgets
    # nothing), or an array of keys.
    # :nodoc:
    def self.forget(store : Cache(K, V), key : T, subscriber : S.class) : Nil forall K, V, T, S
      {% if T <= K %}
        store.delete(key)
      {% elsif T.nilable? && T.union_types.all? { |type| type == Nil || type <= K } %}
        store.delete(key) unless key.nil?
      {% elsif T < Array && T.type_vars[0] <= K %}
        key.each { |one| store.delete(one) }
      {% else %}
        {% raise "@[Punch::Subscriber::Forget] on #{S}: the key is #{T}, but the store's keys are #{K}. The key: getter returns #{K}, #{K}?, or Array(#{K}) (lib/punch/docs/cache.md)." %}
      {% end %}
    end

    # Forgets every entry of *store*: the `call` Punch writes for a
    # subscriber annotated `@[Punch::Subscriber::Forget(STORE)]`, without a key.
    # :nodoc:
    def self.forget_all(store : Store) : Nil
      store.clear
    end

    # The computation of one key in progress, which other fibers that miss
    # the same key wait for (single-flight).
    # :nodoc:
    class Flight(V)
      getter leader : Fiber = Fiber.current
      @done = Channel(Nil).new
      @value : {V}? = nil
      @error : Exception? = nil

      # Only the leader calls these, once each at most: whichever comes
      # first wins.
      def resolve(value : V) : Nil
        return if @done.closed?

        @value = {value}
        @done.close
      end

      def fail(error : Exception) : Nil
        return if @done.closed?

        @error = error
        @done.close
      end

      def wait : V
        @done.receive?
        if error = @error
          raise error
        end
        value = @value || raise "single-flight finished without a value"
        value[0]
      end
    end
  end

  # A typed cache store. Declare one per kind of value, as a constant, with
  # a name that is unique in the app:
  #
  # ```
  # SUMMARIES = Punch::Cache(Customers::ID, Summary).new("customer_summaries", ttl: 10.minutes)
  #
  # summary = SUMMARIES.fetch(customer_id) { build_summary(customer_id) }
  # ```
  #
  # - `fetch` returns the stored value, or runs the block, stores what it
  #   returns, and returns that. Fibers that miss the same key at once wait
  #   for one computation (single-flight; exact within a process, best
  #   effort across two).
  # - *tier* chooses memory, `cache.db`, or memory in front of it
  #   (`Caches::Tier`). Memory holds at most *max_entries*; the file has
  #   one size cap for all stores (`PUNCH_CACHE_MB`). Expired entries go
  #   first, then the oldest.
  # - Values go to the file as JSON and come back through the same parsing
  #   as everything else; a value type with a secret in it does not
  #   compile. A value that no longer parses counts as a miss.
  # - Cache what is expensive to produce: outbound calls, heavy
  #   aggregates, rendered documents. Not rows: a read from `primary.db`
  #   is as fast as one from the cache.
  class Cache(K, V) < Caches::Store
    # How many invalidated keys a store remembers; the oldest falls off
    # into `@floor`.
    INVALIDATIONS = 1024

    getter name : String
    getter ttl : Time::Span
    getter tier : Caches::Tier
    getter max_entries : Int32
    getter shape : String
    getter stats : Caches::Stats = Caches::Stats.new

    @entries = {} of String => {V, Time}
    @lock = Mutex.new
    @flights = {} of String => Caches::Flight(V)
    @flight_lock = Mutex.new
    # When each recently invalidated key was invalidated (`Caches.epoch`),
    # and the newest invalidation that fell off the list or cleared the
    # store: a reading that began before it stores nothing.
    @invalidated = {} of String => Int64
    @floor = 0_i64

    # *durable* replaces the attached file (`Caches.attach`) for this store.
    def initialize(@name : String, *, @ttl : Time::Span, @tier : Caches::Tier = :memory, @max_entries : Int32 = 10_000,
                   @durable : Caches::Durable? = nil)
      typeof(Caches.check_key(K))
      typeof(Caches.check_value(V))
      unless @name.matches?(/\A[a-z][a-z0-9_]{0,62}\z/)
        raise ArgumentError.new("cache name must be lowercase letters, digits, and _, starting with a letter: #{@name.inspect}")
      end
      raise ArgumentError.new("#{@name}: ttl must be positive") unless @ttl.positive?
      raise ArgumentError.new("#{@name}: max_entries must be at least 1") if @max_entries < 1
      @shape = Caches.shape(K, V)
      @span_name = "cache #{@name}"
      Caches.register(self)
    end

    # The value stored under *key*, or the block's value, which is then
    # stored. Inside a Command, the block sees uncommitted data: compute in
    # a Query, or invalidate after commit.
    def fetch(key : K, & : -> V) : V
      unless Caches.enabled?
        Trace.event.add("punch.cache.misses", 1_i64)
        return yield
      end
      text = Caches.key_text(key)
      since = Caches.reading_since
      span = Trace.current.child(@span_name)
      span.set("punch.cache.store", @name) if span.recording?
      begin
        if found = lookup(text, span)
          Trace.event.add("punch.cache.hits", 1_i64)
          return found[0]
        end
        Trace.event.add("punch.cache.misses", 1_i64)
        flight, leader = @flight_lock.synchronize do
          if existing = @flights[text]?
            {existing, false}
          else
            {@flights[text] = Caches::Flight(V).new, true}
          end
        end
        unless leader
          if flight.leader.same?(Fiber.current)
            raise ArgumentError.new("#{@name}: fetch of a key inside the block computing the same key")
          end
          @stats.join
          span.set("punch.cache.result", "joined") if span.recording?
          return flight.wait
        end
        compute(text, flight, span, since) { yield }
      ensure
        span.finish
      end
    end

    # Removes the entry of *key*, from memory and the file.
    def delete(key : K) : Nil
      text = Caches.key_text(key)
      epoch = Caches.invalidated
      @lock.synchronize do
        @entries.delete(text)
        @invalidated.delete(text)
        @invalidated[text] = epoch
        if @invalidated.size > INVALIDATIONS
          _, dropped = @invalidated.shift
          @floor = Math.max(@floor, dropped)
        end
      end
      durable?.try(&.delete(@name, @shape, text))
    end

    def clear : Nil
      clear_memory
      durable?.try(&.clear(@name))
    end

    def clear_memory : Nil
      epoch = Caches.invalidated
      @lock.synchronize do
        @entries.clear
        @invalidated.clear
        @floor = epoch
      end
    end

    # The memory tier's entry count, expired ones included until trimmed.
    def size : Int32
      @lock.synchronize { @entries.size }
    end

    # Whether *key* has a live entry, in memory or in the file, without
    # computing or counting anything: for specs and tools.
    def cached?(key : K) : Bool
      text = Caches.key_text(key)
      now = Time.utc
      unless @tier.durable?
        return true if @lock.synchronize { @entries[text]?.try { |entry| entry[1] > now } }
      end
      return false if @tier.memory?

      !durable?.try(&.get(@name, @shape, text, now)).nil?
    end

    def trim_memory(now : Time = Time.utc) : Int32
      @lock.synchronize do
        before = @entries.size
        @entries.reject! { |_, entry| entry[1] <= now }
        before - @entries.size
      end
    end

    private def compute(text : String, flight : Caches::Flight(V), span : Trace::Span, since : Int64, & : -> V) : V
      started = Time.instant
      begin
        value = yield
        elapsed = Time.instant - started
        @stats.miss(elapsed)
        if span.recording?
          span.set("punch.cache.result", "miss")
          span.set("punch.cache.compute_ms", elapsed.total_milliseconds.round(3))
        end
        store(text, value, since, span)
        flight.resolve(value)
        value
      rescue ex
        flight.fail(ex)
        raise ex
      ensure
        # A `return` or `break` in the block leaves without either; the
        # fibers waiting must not wait forever.
        flight.fail(ArgumentError.new("#{@name}: the block left fetch without a value"))
        @flight_lock.synchronize { @flights.delete(text) }
      end
    end

    private def lookup(text : String, span : Trace::Span) : {V}?
      now = Time.utc
      if @tier.memory? || @tier.both?
        if found = memory_get(text, now)
          @stats.memory_hit
          span.set("punch.cache.result", "memory") if span.recording?
          return found
        end
      end
      return if @tier.memory?

      durable = durable? || return
      since = Caches.epoch
      stored = durable.get(@name, @shape, text, now) || return
      value = begin
        Stored.from_json(V, stored[0])
      rescue ex : JSON::ParseException | TypeCastError
        @stats.error
        Log.warn { "#{@name}: a stored value no longer parses (#{ex.message}); computing it again" }
        return
      end
      @stats.durable_hit
      span.set("punch.cache.result", "durable") if span.recording?
      memory_put(text, value, stored[1], now, since) if @tier.both?
      {value}
    end

    # Keeps *value*, computed from a reading that began at *since*, unless
    # its key was invalidated after that.
    private def store(text : String, value : V, since : Int64, span : Trace::Span) : Nil
      unless current?(text, since)
        span.set("punch.cache.stored", false) if span.recording?
        return
      end
      now = Time.utc
      expires_at = now + @ttl
      memory_put(text, value, expires_at, now, since) unless @tier.durable?
      return if @tier.memory?

      durable = durable? || return
      begin
        @stats.evicted(durable.put(@name, @shape, text, Stored.json(value), expires_at, now))
        # A `delete` between the check and the write found nothing to
        # delete in the file: undo the write.
        durable.delete(@name, @shape, text) unless current?(text, since)
      rescue ex : Database::Error
        @stats.error
        Log.warn(exception: ex) { "#{@name}: writing to cache.db failed; the value is not stored there" }
      end
    end

    private def memory_get(text : String, now : Time) : {V}?
      @lock.synchronize do
        entry = @entries[text]? || return
        return {entry[0]} if entry[1] > now

        @entries.delete(text)
        nil
      end
    end

    # Writes move an entry to the end, so the front holds the oldest
    # writes; with one time-to-live per store, those are also the first to
    # expire.
    # Whether *text* was not invalidated after *since*.
    private def current?(text : String, since : Int64) : Bool
      @lock.synchronize { unlocked_current?(text, since) }
    end

    private def unlocked_current?(text : String, since : Int64) : Bool
      @floor <= since && (@invalidated[text]? || 0_i64) <= since
    end

    private def memory_put(text : String, value : V, expires_at : Time, now : Time, since : Int64) : Nil
      evicted = 0
      @lock.synchronize do
        # Checked under the lock `delete` takes, so no invalidation slips
        # in between.
        next unless unlocked_current?(text, since)

        @entries.delete(text)
        @entries[text] = {value, expires_at}
        while (first = @entries.first?) && first[1][1] <= now
          @entries.shift
        end
        while @entries.size > @max_entries
          @entries.shift
          evicted += 1
        end
      end
      @stats.evicted(evicted)
    end

    private def durable? : Caches::Durable?
      @durable || Caches.durable
    end
  end
end

class Fiber
  # `Punch::Caches.epoch` when the fiber's outermost read transaction
  # began (`Punch::Caches.reading_since`).
  # :nodoc:
  property punch_read_epoch : Int64? = nil
end
