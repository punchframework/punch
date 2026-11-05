require "json"

module Punch::Backup
  # Restores replicas with `litestream restore`, for the recurring restore
  # check (`Verification`) and `punch restore` (`Recovery`).
  #
  # Files are replicated independently, so their replicas end at slightly
  # different times. When one is behind, `target` picks its end as the
  # time to restore every file to; each file is planned up to that time and
  # restored to the last transaction of its plan (`-txid`), so what is
  # restored is exactly what was planned.
  struct Restorer
    # Litestream could not plan or restore a file.
    class Error < Exception
    end

    # What restoring one file takes: its replica's files from the snapshot
    # to *max_txid*. *point* is when the last of them was written to the
    # replica, the time the restored file reaches (Litestream reports it
    # to the second).
    record Plan, name : String, max_txid : String, point : Time, files : Int32, bytes : Int64 do
      include JSON::Serializable
    end

    # One file restored and checked.
    record Restored, name : String, plan : Plan, bytes : Int64, seconds : Float64, integrity : Array(String) do
      def ok? : Bool
        integrity.empty?
      end
    end

    getter litestream : Litestream

    def initialize(@litestream : Litestream)
    end

    # Plans every replicated file's restore to `<name>.db` in *directory*:
    # to its latest point, or with *at* to its last point at that second
    # or before; then, when the earliest replica is behind
    # (`Restorer.target`), every file to the end of the earliest. Returns
    # the time aligned to (`nil` when not aligned) and the plans; each file
    # that cannot be planned is one of *problems*, and the plans are then
    # empty. Downloads nothing.
    def plan_all(directory : String, problems : Array(String), *, at : Time? = nil,
                 behind : Time::Span = BEHIND) : {Time?, Array(Plan)}
      latest = litestream.names.compact_map do |name|
        first = plan(name, to: path(directory, name))
        at ? plan(first, at: at, to: path(directory, name)) : first
      rescue ex : Error
        problems << ex.message.to_s
        nil
      end
      return {nil, [] of Plan} unless latest.size == litestream.names.size

      aligned = Restorer.target(latest, behind)
      return {nil, latest} unless aligned

      plans = latest.compact_map do |first|
        plan(first, at: aligned, to: path(directory, first.name))
      rescue ex : Error
        problems << ex.message.to_s
        nil
      end
      {aligned, plans.size == latest.size ? plans : [] of Plan}
    end

    # Restores every replicated file into *directory* as planned by
    # `plan_all`, and checks each one's integrity. Every failure is one of
    # *problems*; files restored before it are returned all the same.
    def restore_all(directory : String, problems : Array(String), *, at : Time? = nil,
                    behind : Time::Span = BEHIND) : {Time?, Array(Restored)}
      aligned, plans = plan_all(directory, problems, at: at, behind: behind)
      files = plans.compact_map do |plan|
        name = plan.name
        started = Time.instant
        restore(plan, to: path(directory, name))
        seconds = (Time.instant - started).total_seconds
        integrity = Restorer.integrity(path(directory, name))
        problems << "#{name}: integrity check failed: #{integrity.first(3).join("; ")}" unless integrity.empty?
        Restored.new(name, plan, File.size(path(directory, name)), seconds, integrity)
      rescue ex : Error
        problems << ex.message.to_s
        nil
      rescue ex : Database::Error
        problems << "#{name}: the restored file cannot be opened: #{ex.message}"
        nil
      end
      {aligned, files}
    end

    private def path(directory : String, name : String) : String
      File.join(directory, "#{name}.db")
    end

    # `PRAGMA integrity_check`'s findings (up to 20); empty when it is ok.
    def self.integrity(path : String) : Array(String)
      open(path) do |database|
        rows = database.read do |db|
          db.query_all("PRAGMA integrity_check(20)", name: "Punch::Backup::Restorer.integrity_check", &.read(String))
        end
        rows == ["ok"] ? [] of String : rows
      end
    end

    # Opens the restored file at *path* with one reader, for the block.
    def self.open(path : String, & : Database -> T) : T forall T
      database = Database.open(path, config: Database::Config.new(readers: 1))
      begin
        yield database
      ensure
        database.close
      end
    end

    # A replica is behind when its last file is older than the newest
    # replica's by more than this: `Heartbeat` writes to a quiet file at
    # most `INTERVAL + TICK` after its last change, and Litestream uploads
    # it within a sync interval (1 s) or a few.
    BEHIND = Heartbeat::INTERVAL + Heartbeat::TICK + 5.seconds

    # The time to restore every file of *plans* (each planned to its
    # latest) to: the end of the earliest replica, when it is behind the
    # newest; otherwise `nil`, and each file is restored to its latest. A
    # quiet file's replica can end up to `BEHIND` before the others while
    # being current, and aligning to it would throw away the newest writes
    # of the others for nothing.
    def self.target(plans : Enumerable(Plan), behind : Time::Span = BEHIND) : Time?
      earliest = plans.min_of(&.point)
      plans.max_of(&.point) - earliest > behind ? earliest : nil
    end

    # The plan for restoring *latest*'s file to *at*: its last replica
    # file written within that second or before. Litestream restores the
    # files written strictly before a timestamp and refuses one past the
    # replica's last file, so a replica that ends at *at* keeps its latest
    # plan.
    def plan(latest : Plan, at : Time, to path : String) : Plan
      latest.point > at ? plan(latest.name, to: path, before: at + 1.second) : latest
    end

    # The plan for restoring *name* to *path* (left untouched), to its
    # latest point or to the last point before *before*. Downloads
    # nothing.
    def plan(name : String, to path : String, before : Time? = nil) : Plan
      args = ["restore", "-dry-run", "-json"]
      args.push("-timestamp", before.to_utc.to_rfc3339) if before
      args.push("-o", path, litestream.config.replica_url(name))
      output = run(name, args)
      parsed = JSON.parse(output)
      files = parsed["files"].as_a
      raise Error.new("#{name}: the replica has no files to restore") if files.empty?
      point = files.max_of { |file| Time::Format::RFC_3339.parse(file["timestamp"].as_s) }
      Plan.new(name, parsed["max_txid"].as_s, point, files.size, files.sum(0_i64, &.["size"].as_i64))
    rescue ex : JSON::ParseException | TypeCastError | KeyError | Time::Format::Error
      raise Error.new("#{name}: Litestream's plan could not be read (#{ex.message})")
    end

    # Restores *plan*'s file to *path*, which must not exist, up to the
    # plan's last transaction.
    def restore(plan : Plan, to path : String) : Nil
      run(plan.name, ["restore", "-txid", plan.max_txid, "-o", path, litestream.config.replica_url(plan.name)])
      raise Error.new("#{plan.name}: Litestream reported success but wrote no file at #{path}") unless File.exists?(path)
    end

    # Litestream's standard output, or an `Error` with its message.
    private def run(name : String, args : Array(String)) : String
      program = litestream.executable || raise Error.new(litestream.problem || "Litestream not found")
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(program, args, env: Litestream.environment, clear_env: true, output: output, error: error)
      return output.to_s if status.success?

      raise Error.new("#{name}: #{Restorer.reason(error.to_s)}")
    rescue ex : IO::Error | File::Error
      raise Error.new("#{name}: Litestream could not run (#{ex.message})")
    end

    # The line of Litestream's error output that says what went wrong:
    # `Error: …`, else the last line.
    def self.reason(stderr : String) : String
      lines = stderr.lines.map(&.strip).reject(&.empty?)
      lines.reverse.find(&.starts_with?("Error:")).try(&.lchop("Error:").strip) || lines.last? || "exited without a message"
    end
  end
end
