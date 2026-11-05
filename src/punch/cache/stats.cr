module Punch::Caches
  # Counters of one store since the process started: what `fetch` found
  # where, and what computing a miss cost. Thread-safe; read with
  # `snapshot`.
  class Stats
    @memory_hits = Atomic(Int64).new(0)
    @durable_hits = Atomic(Int64).new(0)
    @misses = Atomic(Int64).new(0)
    @joins = Atomic(Int64).new(0)
    @compute_ns = Atomic(Int64).new(0)
    @evictions = Atomic(Int64).new(0)
    @errors = Atomic(Int64).new(0)

    # The counters at one moment.
    record Snapshot, memory_hits : Int64, durable_hits : Int64, misses : Int64, joins : Int64,
      compute_ms : Float64, evictions : Int64, errors : Int64 do
      include JSON::Serializable

      def hits : Int64
        memory_hits + durable_hits
      end

      # Hits among all fetches that did not wait for another's computation;
      # `nil` before the first fetch.
      def hit_rate : Float64?
        total = hits + misses
        total > 0 ? hits / total : nil
      end
    end

    # A fetch answered from memory.
    def memory_hit : Nil
      @memory_hits.add(1, :relaxed)
    end

    # A fetch answered from `cache.db`.
    def durable_hit : Nil
      @durable_hits.add(1, :relaxed)
    end

    # A fetch that computed its value, and how long that took.
    def miss(elapsed : Time::Span) : Nil
      @misses.add(1, :relaxed)
      @compute_ns.add(elapsed.total_nanoseconds.to_i64, :relaxed)
    end

    # A fetch that waited for another fiber computing the same key.
    def join : Nil
      @joins.add(1, :relaxed)
    end

    # Entries removed to stay within a size cap.
    def evicted(count : Int) : Nil
      @evictions.add(count.to_i64, :relaxed) if count > 0
    end

    # A stored value that no longer parsed, or a failed write to the file.
    def error : Nil
      @errors.add(1, :relaxed)
    end

    def snapshot : Snapshot
      Snapshot.new(@memory_hits.get(:relaxed), @durable_hits.get(:relaxed), @misses.get(:relaxed), @joins.get(:relaxed),
        (@compute_ns.get(:relaxed) / 1_000_000).round(3), @evictions.get(:relaxed), @errors.get(:relaxed))
    end
  end
end
