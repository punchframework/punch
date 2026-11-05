module Punch::CLI::Commands
  # Helpers shared by the cache commands, which work on `cache.db` in
  # `PUNCH_STORAGE` (docs/cache.md). Memory stores live inside the server
  # process; these commands see only the file.
  module CacheCommand
    # Runs *block* with the cache file, or answers without one.
    def self.with_durable(& : Punch::Caches::Durable, String, Punch::AppConfig -> Report | Failure) : Report | Failure
      settings = Config.settings
      return settings if settings.is_a?(Failure)

      path = File.join(settings.storage, "cache.db")
      return Failure.new("no_database", "#{path} does not exist; serve creates it.") unless File.exists?(path)

      database = Punch::Database.open(path, name: "cache", config: Punch::Database::Config.new(readers: 1))
      begin
        yield Punch::Caches::Durable.new(database, settings.cache_bytes), path, settings
      ensure
        database.close
      end
    rescue ex : Punch::Database::Error | Punch::Database::FilesystemError
      Failure.new("database_error", ex.message || "database error")
    end
  end

  # Entries and bytes in `cache.db`, per store and shape. A store with
  # more than one shape still holds entries of an older value type, which
  # expire or go first when the file is full.
  class CacheStats < Command
    command "cache:stats", "Show entries and bytes per store in cache.db"

    struct Result
      include Report

      def initialize(@path : String, @bytes : Int64, @max_bytes : Int64, @usage : Array(Punch::Caches::Durable::Usage))
      end

      def to_text(io : IO) : Nil
        io.puts "#{@path}: #{megabytes(@bytes)} of #{megabytes(@max_bytes)} MiB"
        io.puts "No entries." if @usage.empty?
        @usage.each do |usage|
          io.puts "  #{usage.store.ljust(24)} #{usage.shape}  #{usage.entries.to_s.rjust(8)} entries  " \
                  "#{usage.expired.to_s.rjust(8)} expired  #{megabytes(usage.bytes).to_s.rjust(8)} MiB"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", @path
          json.field "bytes", @bytes
          json.field "max_bytes", @max_bytes
          json.field "stores", @usage
        end
      end

      private def megabytes(bytes : Int64) : Float64
        (bytes / 1024 / 1024).round(2)
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      CacheCommand.with_durable do |durable, path|
        Result.new(path, durable.bytes, durable.max_bytes, durable.usage(Time.utc))
      end
    end
  end

  # Removes entries from `cache.db`: of one store, or all; with
  # `--expired`, only expired ones.
  class CacheClear < Command
    command "cache:clear", "Remove entries from cache.db: punch cache:clear [STORE] [--expired]"

    struct Result
      include Report

      def initialize(@removed : Int64)
      end

      def to_text(io : IO) : Nil
        io.puts "Removed #{@removed} entr#{@removed == 1 ? "y" : "ies"}."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "removed", @removed }
      end
    end

    def run(args : Array(String)) : Report | Failure
      expired = args.includes?("--expired")
      rest = args.reject("--expired")
      return Failure.usage("unexpected_argument", "Usage: punch cache:clear [STORE] [--expired]") if rest.size > 1 || rest.any?(&.starts_with?("--"))

      CacheCommand.with_durable do |durable|
        Result.new(durable.clear(rest.first?, expired_at: expired ? Time.utc : nil))
      end
    end
  end
end
