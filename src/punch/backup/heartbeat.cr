module Punch::Backup
  # Keeps every replica current to within `INTERVAL`: Litestream uploads
  # a file only when its database changes, so the replica of a quiet file
  # ends at its last write, and from the replica alone a quiet file cannot
  # be told from one whose uploads stopped. Each replicated file that
  # has not changed for `INTERVAL` gets one row written to
  # `_punch_heartbeat` (one row, its time), which Litestream uploads like
  # any change; files are looked at every `TICK`.
  #
  # So while Litestream runs, every replica has a file at most
  # `INTERVAL + TICK` old, and a replica whose last file is clearly older
  # than the others' is behind (`Restorer.target`). Busy files get no
  # extra writes. The table is Punch's, created on the first beat, and left out
  # of schema dumps like Litestream's own.
  class Heartbeat
    INTERVAL = 15.seconds
    TICK     = 5.seconds

    @stop = Channel(Nil).new
    @started = false

    def initialize(@databases : Array(Database), @tracer : Trace::Tracer = Trace::Tracer.off)
    end

    def start : Nil
      return if @started || @databases.empty?

      @started = true
      spawn(name: "punch.backup.heartbeat") do
        loop do
          select
          when @stop.receive?
            break
          when timeout(TICK)
            beat
          end
        end
      end
    end

    def stop : Nil
      @stop.close
    end

    # Writes to each file that has not changed for `INTERVAL` before
    # *now*; returns their names.
    def beat(now : Time = Time.utc) : Array(String)
      @databases.compact_map do |database|
        next if database.closed?
        changed = Monitor.changed_at(database.path)
        next if changed && now - changed < INTERVAL
        database.write do |db|
          db.exec("CREATE TABLE IF NOT EXISTS _punch_heartbeat (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL) STRICT",
            name: "Punch::Backup::Heartbeat.table")
          db.exec("INSERT INTO _punch_heartbeat (id, at) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET at = excluded.at",
            now.to_unix_ms, name: "Punch::Backup::Heartbeat.beat")
        end
        database.name
      rescue ex : Database::Error
        # The next beat tries again; one closed meanwhile is shutting down.
        @tracer.report(ex, "backup") unless database.closed?
        nil
      end
    end
  end
end
