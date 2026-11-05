module Punch::Caches
  # The durable tier: entries in `cache.db`, which survives restarts and is
  # shared by two processes on one file. The file is Punch's own and can be
  # rebuilt: it is not replicated, and its tables are created here, outside
  # the app's migrations. A file with an older layout is emptied and
  # recreated.
  #
  # The file has a size cap. A write that takes it over the cap first
  # removes expired entries, then those closest to expiry, until it is back
  # under 90 % of the cap. The running total is kept by triggers, so both
  # processes see the same number.
  class Durable
    # Bumped whenever the tables change; a file with another version is
    # dropped and recreated.
    LAYOUT = 1

    DEFAULT_MAX_BYTES = 256_i64 * 1024 * 1024

    # Stored per entry on top of key and value: a rough row overhead, so a
    # cap of many tiny entries still means something.
    ROW_OVERHEAD = 32

    # Dropped when the layout changes; the cache is rebuilt empty.
    DROP = {"DROP TABLE IF EXISTS punch_cache", "DROP TABLE IF EXISTS punch_cache_size"}

    TABLES = {
      <<-SQL,
        CREATE TABLE punch_cache (
          store      TEXT    NOT NULL,
          shape      TEXT    NOT NULL,
          key        TEXT    NOT NULL,
          value      TEXT    NOT NULL,
          expires_at INTEGER NOT NULL,
          size       INTEGER NOT NULL,
          PRIMARY KEY (store, shape, key)
        ) STRICT, WITHOUT ROWID
        SQL
      "CREATE INDEX punch_cache_by_expiry ON punch_cache (expires_at)",
      "CREATE TABLE punch_cache_size (id INTEGER PRIMARY KEY CHECK (id = 1), bytes INTEGER NOT NULL) STRICT",
      "INSERT INTO punch_cache_size (id, bytes) VALUES (1, 0)",
      "CREATE TRIGGER punch_cache_added AFTER INSERT ON punch_cache BEGIN UPDATE punch_cache_size SET bytes = bytes + new.size; END",
      "CREATE TRIGGER punch_cache_removed AFTER DELETE ON punch_cache BEGIN UPDATE punch_cache_size SET bytes = bytes - old.size; END",
      "CREATE TRIGGER punch_cache_changed AFTER UPDATE ON punch_cache BEGIN UPDATE punch_cache_size SET bytes = bytes - old.size + new.size; END",
    }

    # Entries and bytes of one store's shape, for `cache:stats`.
    record Usage, store : String, shape : String, entries : Int64, expired : Int64, bytes : Int64 do
      include JSON::Serializable
    end

    getter database : Database
    getter max_bytes : Int64

    def initialize(@database : Database, @max_bytes : Int64 = DEFAULT_MAX_BYTES)
      raise ArgumentError.new("max_bytes must be positive") unless @max_bytes > 0
      @database.write { |db| setup(db) }
    end

    # The stored value of *key* and its expiry, unless absent or expired at
    # *now*.
    def get(store : String, shape : String, key : String, now : Time) : {String, Time}?
      @database.read do |db|
        db.query_one?("SELECT value, expires_at FROM punch_cache WHERE store = ? AND shape = ? AND key = ? AND expires_at > ?",
          store, shape, key, now.to_unix_ms, name: "Punch::Caches::Durable.get") do |row|
          {row.read(String), Time.unix_ms(row.read(Int64))}
        end
      end
    end

    # Stores *value* until *expires_at* and returns how many live entries
    # were removed to stay within the cap (expired ones are not counted).
    def put(store : String, shape : String, key : String, value : String, expires_at : Time, now : Time) : Int64
      size = store.bytesize + shape.bytesize + key.bytesize + value.bytesize + ROW_OVERHEAD
      @database.write do |db|
        db.exec(<<-SQL, store, shape, key, value, expires_at.to_unix_ms, size, name: "Punch::Caches::Durable.put")
          INSERT INTO punch_cache (store, shape, key, value, expires_at, size) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (store, shape, key) DO UPDATE SET value = excluded.value, expires_at = excluded.expires_at, size = excluded.size
          SQL
        bytes(db) > @max_bytes ? trim(db, now, @max_bytes * 9 // 10)[1] : 0_i64
      end
    end

    def delete(store : String, shape : String, key : String) : Nil
      @database.write do |db|
        db.exec("DELETE FROM punch_cache WHERE store = ? AND shape = ? AND key = ?", store, shape, key, name: "Punch::Caches::Durable.delete")
      end
    end

    # Removes every entry of *store* (all its shapes), or of every store;
    # with *expired_at*, only entries expired by then. Returns the count.
    def clear(store : String? = nil, *, expired_at : Time? = nil) : Int64
      @database.write do |db|
        before = expired_at.try(&.to_unix_ms) || Int64::MAX
        if store
          db.exec("DELETE FROM punch_cache WHERE store = ? AND expires_at <= ?", store, before).changes
        else
          db.exec("DELETE FROM punch_cache WHERE expires_at <= ?", before).changes
        end
      end
    end

    # Removes expired entries, then the closest to expiry while the file
    # holds more than *target* bytes. Returns the count removed.
    def trim(now : Time, target : Int64 = @max_bytes) : Int64
      @database.write { |db| trim(db, now, target).sum }
    end

    # The bytes held, by the running total.
    def bytes : Int64
      @database.read { |db| bytes(db) }
    end

    # Entries and bytes per store and shape at *now*.
    def usage(now : Time) : Array(Usage)
      @database.read do |db|
        db.query_all(<<-SQL, now.to_unix_ms) do |row|
          SELECT store, shape, count(*), sum(expires_at <= ?), sum(size)
          FROM punch_cache GROUP BY store, shape ORDER BY store, shape
          SQL
          Usage.new(row.read(String), row.read(String), row.read(Int64), row.read(Int64), row.read(Int64))
        end
      end
    end

    private def bytes(db : Reader | Writer) : Int64
      db.query_one?("SELECT bytes FROM punch_cache_size", &.read(Int64)) || 0_i64
    end

    # Expired entries removed, and live ones: those closest to expiry
    # until their sizes add up to what must go.
    private def trim(db : Writer, now : Time, target : Int64) : {Int64, Int64}
      expired = db.exec("DELETE FROM punch_cache WHERE expires_at <= ?", now.to_unix_ms, name: "Punch::Caches::Durable.trim").changes
      excess = bytes(db) - target
      return {expired, 0_i64} if excess <= 0
      removed = db.exec(<<-SQL, excess, name: "Punch::Caches::Durable.trim").changes
        DELETE FROM punch_cache WHERE (store, shape, key) IN (
          SELECT store, shape, key FROM (
            SELECT store, shape, key, size,
              sum(size) OVER (ORDER BY expires_at, store, shape, key ROWS UNBOUNDED PRECEDING) AS freed
            FROM punch_cache
          ) WHERE freed - size < ?
        )
        SQL
      {expired, removed}
    end

    private def setup(db : Writer) : Nil
      # Rate limits keep their own table here, outside the cache's layout.
      RateLimits.create_tables(db)
      # So are the bans of addresses that probe (`HTTP::Probes`).
      HTTP::Probes.create_tables(db)
      version = db.query_one?("PRAGMA user_version", &.read(Int64))
      return if version == LAYOUT && db.query_one?("SELECT 1 FROM sqlite_schema WHERE name = 'punch_cache'", &.read(Int64))

      DROP.each { |sql| db.exec(sql) }
      TABLES.each { |sql| db.exec(sql) }
      db.exec("PRAGMA user_version = #{LAYOUT}")
    end
  end
end
