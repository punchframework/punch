require "../spec_helper"

module CacheSpec
  struct CustomerID < Punch::TypedID
  end

  enum Kind
    Open
    Paid
  end

  struct Summary
    include JSON::Serializable

    getter customer_id : CustomerID
    getter email : Punch::Email
    getter total : Punch::Money
    getter kinds : Array(Kind)

    def initialize(@customer_id, @email, @total, @kinds)
    end
  end

  # Another shape under the same name, as after a deploy that changed it.
  struct SummaryV2
    include JSON::Serializable

    getter customer_id : CustomerID
    getter outstanding : Int64

    def initialize(@customer_id, @outstanding)
    end
  end

  def self.id(value : Int64) : CustomerID
    CustomerID.parse(value).as(CustomerID)
  end

  def self.summary(value : Int64) : Summary
    Summary.new(id(value), Punch::Email.parse("c#{value}@example.org").as(Punch::Email),
      Punch::Money.parse(value * 100).as(Punch::Money), [Kind::Open, Kind::Paid])
  end

  def self.durable(file : Bool = false, max_bytes : Int64 = Punch::Caches::Durable::DEFAULT_MAX_BYTES, & : Punch::Caches::Durable ->) : Nil
    Punch::Spec.database(file: file) { |database| yield Punch::Caches::Durable.new(database, max_bytes) }
  end
end

describe Punch::Cache do
  it "computes a miss once and answers later fetches from memory" do
    cache = Punch::Cache(String, Int32).new("memory_basic", ttl: 1.minute)
    calls = 0
    3.times { cache.fetch("a") { calls += 1; 42 }.should eq(42) }
    calls.should eq(1)
    cache.fetch("b") { 7 }.should eq(7)
    stats = cache.stats.snapshot
    {stats.memory_hits, stats.misses, stats.durable_hits}.should eq({2, 2, 0})
    stats.hit_rate.should eq(0.5)
  end

  it "keeps tuple keys apart from strings that look like them" do
    cache = Punch::Cache({String, String}, String).new("tuple_keys", ttl: 1.minute)
    other = Punch::Cache(String, String).new("tuple_keys_flat", ttl: 1.minute)
    cache.fetch({"a,b", "c"}) { "one" }
    cache.fetch({"a", "b,c"}) { "two" }.should eq("two")
    Punch::Caches.key_text({"a", "b"}).should_not eq(Punch::Caches.key_text(%(["a","b"])))
    other.fetch(%(["a","b"])) { "flat" }.should eq("flat")
  end

  it "expires entries after the time-to-live" do
    clock = Punch::Spec.clock
    cache = Punch::Cache(Int64, Int64).new("expiry", ttl: 10.minutes)
    cache.fetch(1_i64) { 1_i64 }
    clock.advance(9.minutes)
    cache.fetch(1_i64) { 2_i64 }.should eq(1)
    clock.advance(1.minute)
    cache.fetch(1_i64) { 3_i64 }.should eq(3)
  end

  it "holds at most max_entries in memory, dropping expired and then the oldest writes first" do
    clock = Punch::Spec.clock
    cache = Punch::Cache(Int32, Int32).new("bounded", ttl: 1.minute, max_entries: 3)
    (1..3).each { |key| cache.fetch(key) { key } }
    cache.fetch(4) { 4 }
    cache.size.should eq(3)
    cache.stats.snapshot.evictions.should eq(1)
    cache.fetch(1) { -1 }.should eq(-1) # evicted, computed again
    clock.advance(2.minutes)
    cache.fetch(5) { 5 }
    cache.size.should eq(1) # the expired ones went before any eviction
    cache.stats.snapshot.evictions.should eq(2)
  end

  it "lets one fiber compute a key that many miss at once, on several threads" do
    cache = Punch::Cache(String, Int32).new("single_flight", ttl: 1.minute)
    computations = Atomic(Int32).new(0)
    results = Channel(Int32).new(32)
    32.times do
      spawn do
        results.send(cache.fetch("hot") { computations.add(1); sleep 50.milliseconds; 99 })
      end
    end
    Array.new(32) { results.receive }.uniq.should eq([99])
    computations.get.should eq(1)
    stats = cache.stats.snapshot
    (stats.joins + stats.memory_hits).should eq(31)
    stats.joins.should be > 0
  end

  it "hands the computing fiber's exception to the fibers waiting, and computes again after" do
    cache = Punch::Cache(String, Int32).new("flight_error", ttl: 1.minute)
    started = Channel(Nil).new
    outcomes = Channel(String).new(2)
    spawn do
      cache.fetch("k") { started.send(nil); sleep 30.milliseconds; raise "upstream down" }
    rescue ex
      outcomes.send("leader: #{ex.message}")
    end
    started.receive
    spawn do
      cache.fetch("k") { 1 }
      outcomes.send("waiter: value")
    rescue ex
      outcomes.send("waiter: #{ex.message}")
    end
    Array.new(2) { outcomes.receive }.sort.should eq(["leader: upstream down", "waiter: upstream down"])
    cache.fetch("k") { 2 }.should eq(2)
  end

  it "releases waiting fibers when the block leaves fetch with return" do
    cache = Punch::Cache(String, Int32).new("flight_return", ttl: 1.minute)
    started = Channel(Nil).new
    waiter = Channel(String).new(1)
    leave = ->(gate : Channel(Nil)) do
      cache.fetch("k") do
        gate.send(nil)
        sleep 30.milliseconds
        next 0 if gate.closed? # never: keeps the block's type
        return 5
      end
      -1
    end
    spawn { leave.call(started) }
    started.receive
    spawn do
      waiter.send(cache.fetch("k") { 1 }.to_s)
    rescue ex
      waiter.send(ex.message.to_s)
    end
    waiter.receive.should contain("left fetch without a value")
    cache.fetch("k") { 3 }.should eq(3)
  end

  it "refuses to wait for itself when the block fetches its own key" do
    cache = Punch::Cache(String, Int32).new("reentrant", ttl: 1.minute)
    expect_raises(ArgumentError, /inside the block computing the same key/) do
      cache.fetch("k") { cache.fetch("k") { 1 } }
    end
    cache.fetch("k") { 2 }.should eq(2)
  end

  it "computes every time while caching is off" do
    cache = Punch::Cache(String, Int32).new("off", ttl: 1.minute)
    calls = 0
    Punch::Spec.without_cache do
      2.times { cache.fetch("a") { calls += 1 } }
    end
    calls.should eq(2)
    cache.fetch("a") { calls += 1 }
    cache.fetch("a") { calls += 1 }.should eq(3)
  end

  it "deletes one key and clears a store" do
    CacheSpec.durable do |durable|
      cache = Punch::Cache(String, Int32).new("deleting", ttl: 1.minute, tier: :both, durable: durable)
      cache.fetch("a") { 1 }
      cache.fetch("b") { 2 }
      cache.delete("a")
      cache.fetch("a") { 10 }.should eq(10)
      cache.fetch("b") { 20 }.should eq(2)
      cache.clear
      cache.size.should eq(0)
      durable.usage(Time.utc).should be_empty
    end
  end

  it "does not store a value whose key was deleted while it was computed" do
    CacheSpec.durable do |durable|
      cache = Punch::Cache(String, Int32).new("deleted_in_flight", ttl: 1.minute, tier: :both, durable: durable)
      cache.fetch("a") { cache.delete("a"); 1 }.should eq(1)
      cache.cached?("a").should be_false
      durable.usage(Time.utc).should be_empty
      cache.fetch("a") { 2 }.should eq(2)
      cache.cached?("a").should be_true
    end
  end

  it "does not store a value computed from a snapshot older than its key's invalidation" do
    Punch::Spec.database(file: true) do |database|
      database.write(&.exec("CREATE TABLE totals (id INTEGER PRIMARY KEY, total INTEGER NOT NULL)"))
      database.write(&.exec("INSERT INTO totals (id, total) VALUES (1, 100)"))
      cache = Punch::Cache(Int64, Int64).new("snapshot_race", ttl: 1.minute)
      total = ->(reader : Punch::Reader) { reader.query_one?("SELECT total FROM totals WHERE id = 1", &.read(Int64)) || 0_i64 }

      database.read do |reader|
        total.call(reader).should eq(100) # the snapshot starts here
        # A Command commits a change; its Forget runs after the commit.
        database.write(&.exec("UPDATE totals SET total = 250 WHERE id = 1"))
        cache.delete(1_i64)
        cache.fetch(1_i64) { total.call(reader) }.should eq(100)
        cache.cached?(1_i64).should be_false
        # A key nobody invalidated is kept.
        cache.fetch(2_i64) { 7_i64 }
        cache.cached?(2_i64).should be_true
      end

      database.read { |reader| cache.fetch(1_i64) { total.call(reader) } }.should eq(250)
      cache.cached?(1_i64).should be_true
    end
  end

  it "stores nothing computed in a reading that began before the store was cleared" do
    Punch::Spec.database do |database|
      cache = Punch::Cache(String, Int32).new("cleared_reading", ttl: 1.minute)
      database.read do
        cache.clear
        cache.fetch("a") { 1 }
        cache.cached?("a").should be_false
      end
      database.read { cache.fetch("a") { 2 } }
      cache.cached?("a").should be_true
    end
  end

  it "stays bounded in what it remembers of invalidations, storing less rather than stale" do
    Punch::Spec.database do |database|
      cache = Punch::Cache(Int32, Int32).new("many_invalidations", ttl: 1.minute)
      database.read do
        (Punch::Cache::INVALIDATIONS + 1).times { |key| cache.delete(key) }
        cache.fetch(-1) { 1 }
        cache.cached?(-1).should be_false
      end
      cache.fetch(-1) { 1 }
      cache.cached?(-1).should be_true
    end
  end

  it "records hits and misses on the wide event and a span per fetch" do
    cache = Punch::Cache(String, Int32).new("traced", ttl: 1.minute)
    trace = Punch::Spec.trace do
      cache.fetch("a") { 1 }
      cache.fetch("a") { 1 }
    end
    trace.should have_span("cache traced", "punch.cache.result": "miss", "punch.cache.store": "traced")
    trace.should have_span("cache traced", "punch.cache.result": "memory")
    trace.root.attributes["punch.cache.hits"].should eq(1)
    trace.root.attributes["punch.cache.misses"].should eq(1)
  end

  it "tells whether a key is cached without computing or counting" do
    CacheSpec.durable do |durable|
      memory = Punch::Cache(String, Int32).new("peek_memory", ttl: 1.minute)
      file = Punch::Cache(String, Int32).new("peek_file", ttl: 1.minute, tier: :durable, durable: durable)
      clock = Punch::Spec.clock
      expiring = Punch::Cache(String, Int32).new("peek_expiring", ttl: 1.minute, tier: :both, durable: durable)
      [memory, file, expiring].each do |cache|
        cache.cached?("a").should be_false
        cache.fetch("a") { 1 }
        cache.cached?("a").should be_true
        cache.stats.snapshot.misses.should eq(1)
      end
      clock.advance(2.minutes)
      expiring.cached?("a").should be_false
    end
  end

  it "forgets a key, a nilable key, or an array of keys, as @[Punch::Subscriber::Forget] subscribers do" do
    cache = Punch::Cache(Int64, Int32).new("forgetting", ttl: 1.minute)
    (1_i64..4_i64).each { |key| cache.fetch(key) { 1 } }
    Punch::Caches.forget(cache, 1_i64, CacheSpec::Summary)
    Punch::Caches.forget(cache, nil.as(Int64?), CacheSpec::Summary)
    Punch::Caches.forget(cache, 2_i64.as(Int64?), CacheSpec::Summary)
    Punch::Caches.forget(cache, [3_i64], CacheSpec::Summary)
    (1_i64..4_i64).map { |key| cache.cached?(key) }.should eq([false, false, false, true])
    Punch::Caches.forget_all(cache)
    cache.size.should eq(0)
  end

  it "trims expired entries from memory and from cache.db with the recurring job" do
    memory = Punch::Cache(String, Int32).new("trim_memory", ttl: 1.millisecond)
    memory.fetch("a") { 1 }
    durable = Punch::Caches.durable || fail "cache.db is not attached"
    durable.put("trim_file", "shape", %("a"), "1", Time.utc - 1.second, Time.utc)
    durable.put("trim_file", "shape", %("b"), "2", Time.utc + 1.minute, Time.utc)
    sleep 5.milliseconds
    memory.size.should eq(1) # expired, but nothing wrote since
    Punch::Spec.queue.enqueue(Punch::Caches::Trim.new)
    Punch::Spec.perform_jobs
    memory.size.should eq(0)
    durable.usage(Time.utc).select(&.store.==("trim_file")).map { |usage| {usage.entries, usage.expired} }.should eq([{1, 0}])
    Punch::Job::Queue.tasks.find!(&.type.==("Punch::Caches::Trim")).schedule.to_s.should eq("every 00:10:00")
  end

  it "rejects bad names and settings when declared" do
    expect_raises(ArgumentError, /cache name/) { Punch::Cache(String, Int32).new("Bad-Name", ttl: 1.minute) }
    expect_raises(ArgumentError, /ttl/) { Punch::Cache(String, Int32).new("no_ttl", ttl: 0.seconds) }
    expect_raises(ArgumentError, /max_entries/) { Punch::Cache(String, Int32).new("no_room", ttl: 1.minute, max_entries: 0) }
  end

  describe "in cache.db" do
    it "stores values as JSON and reads domain types back through their parsers" do
      CacheSpec.durable do |durable|
        cache = Punch::Cache(CacheSpec::CustomerID, CacheSpec::Summary).new("summaries", ttl: 1.minute, tier: :durable, durable: durable)
        id = CacheSpec.id(7)
        cache.fetch(id) { CacheSpec.summary(7) }
        found = cache.fetch(id) { raise "not cached" }
        found.to_json.should eq(CacheSpec.summary(7).to_json)
        found.email.should be_a(Punch::Email)
        cache.size.should eq(0) # nothing in memory
        cache.stats.snapshot.durable_hits.should eq(1)
      end
    end

    it "is shared by two processes and survives a restart" do
      CacheSpec.durable(file: true) do |durable|
        first = Punch::Cache(String, String).new("shared", ttl: 1.minute, tier: :both, durable: durable)
        first.fetch("k") { "from the first" }
        other = Punch::Caches::Durable.new(Punch::Database.open(durable.database.path, name: "cache"))
        begin
          second = Punch::Cache(String, String).new("shared", ttl: 1.minute, tier: :both, durable: other)
          second.fetch("k") { "computed again" }.should eq("from the first")
          second.size.should eq(1) # copied into its memory in front
        ensure
          other.database.close
        end
      end
    end

    it "keeps a changed value type apart under the same name" do
      CacheSpec.durable do |durable|
        old = Punch::Cache(CacheSpec::CustomerID, CacheSpec::Summary).new("versions", ttl: 1.minute, tier: :durable, durable: durable)
        new = Punch::Cache(CacheSpec::CustomerID, CacheSpec::SummaryV2).new("versions", ttl: 1.minute, tier: :durable, durable: durable)
        old.shape.should_not eq(new.shape)
        old.fetch(CacheSpec.id(1)) { CacheSpec.summary(1) }
        new.fetch(CacheSpec.id(1)) { CacheSpec::SummaryV2.new(CacheSpec.id(1), 5) }.outstanding.should eq(5)
        durable.usage(Time.utc).map(&.shape).sort!.should eq([old.shape, new.shape].sort!)
      end
    end

    it "treats a stored value that no longer parses as a miss" do
      CacheSpec.durable do |durable|
        cache = Punch::Cache(CacheSpec::CustomerID, CacheSpec::Summary).new("damaged", ttl: 1.minute, tier: :durable, durable: durable)
        cache.fetch(CacheSpec.id(1)) { CacheSpec.summary(1) }
        durable.database.write(&.exec(%(UPDATE punch_cache SET value = '{"customer_id":0}')))
        cache.fetch(CacheSpec.id(1)) { CacheSpec.summary(2) }.customer_id.should eq(CacheSpec.id(2))
        cache.stats.snapshot.errors.should eq(1)
      end
    end

    it "does not return expired entries" do
      clock = Punch::Spec.clock
      CacheSpec.durable do |durable|
        cache = Punch::Cache(String, Int32).new("durable_expiry", ttl: 1.minute, tier: :durable, durable: durable)
        cache.fetch("a") { 1 }
        clock.advance(61.seconds)
        cache.fetch("a") { 2 }.should eq(2)
      end
    end

    it "stays under its size cap, removing expired entries first and then those closest to expiry" do
      clock = Punch::Spec.clock
      CacheSpec.durable(max_bytes: 20_000) do |durable|
        short = Punch::Cache(Int32, String).new("short", ttl: 1.minute, tier: :durable, durable: durable)
        long = Punch::Cache(Int32, String).new("long", ttl: 1.hour, tier: :durable, durable: durable)
        value = "x" * 400
        (1..20).each { |key| short.fetch(key) { value } }
        clock.advance(2.minutes) # the short ones have expired
        (1..25).each { |key| clock.advance(1.second); long.fetch(key) { value } }
        # Over the cap at the 22nd write: the expired ones went, nothing else.
        durable.usage(clock.now).map { |usage| {usage.store, usage.entries} }.should eq([{"long", 25}])
        long.stats.snapshot.evictions.should eq(0)
        (26..80).each { |key| clock.advance(1.second); long.fetch(key) { value } }
        durable.bytes.should be <= 20_000
        durable.bytes.should be > 17_000 # down to 90 % of the cap, not further
        kept = durable.database.read(&.query_all("SELECT key FROM punch_cache ORDER BY expires_at", &.read(String)))
        kept.last.should eq("80")
        kept.first.to_i.should be > 26 # the earliest writes expire first, so they went
        long.stats.snapshot.evictions.should be > 0
        durable.bytes.should eq(durable.database.read(&.query_one?("SELECT sum(size) FROM punch_cache", &.read(Int64))))
      end
    end

    it "recreates a file of another layout and counts bytes across clears" do
      Punch::Spec.database do |database|
        database.write(&.exec("PRAGMA user_version = 99"))
        durable = Punch::Caches::Durable.new(database)
        cache = Punch::Cache(String, String).new("layout", ttl: 1.minute, tier: :durable, durable: durable)
        cache.fetch("a") { "value" }
        durable.bytes.should be > 0
        durable.clear("layout").should eq(1)
        durable.bytes.should eq(0)
        database.read(&.query_one?("PRAGMA user_version", &.read(Int64))).should eq(Punch::Caches::Durable::LAYOUT)
      end
    end
  end
end
