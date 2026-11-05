module Punch
  class Database
    # Which version of each collation a database's indexes were built with
    # (a collation never changes silently). The migrator records the
    # versions of the collations the schema uses, `db/schema.sql` carries
    # them, and opening a database file whose recorded version differs from
    # the binary's fails: its indexes are ordered by the old rules, so
    # lookups and uniqueness would be wrong. The way forward is a migration
    # with `REINDEX <name>;`, which the migrator records.
    #
    # Punch's own `lower`, `upper`, and `like` (`docs/text.md`) are
    # versioned the same way, recorded as `lower()` and so on when an
    # index uses them: their rules come from Crystal's Unicode tables, and
    # an expression index built with older ones holds stale keys. A
    # migration with `REINDEX EXPRESSIONS;` (or a bare `REINDEX;`) rebuilds
    # those indexes.
    module CollationVersions
      TABLE = "punch_collations"

      # Punch's text functions, as recorded, and the version of their
      # rules: raised when Punch changes them, and with Crystal's Unicode
      # version.
      FUNCTIONS        = %w[lower() upper() like()]
      FUNCTION_RULES   = 1
      FUNCTION_VERSION = "punch-text-#{FUNCTION_RULES}/unicode-#{Unicode::VERSION}"
      USES             = {
        "lower()" => /\blower\s*\(/i,
        "upper()" => /\bupper\s*\(/i,
        "like()"  => /\blike\b/i,
      }

      # SQLite's own collations, which never change.
      SQLITE = %w[binary nocase rtrim]

      COLLATE     = /\bCOLLATE\s+(?:"([^"]+)"|'([^']+)'|`([^`]+)`|\[([^\]]+)\]|(\w+))/i
      REINDEX     = /\bREINDEX\s+(?:"([^"]+)"|(\w+))/i
      REINDEX_ALL = /\bREINDEX\s*(?:;|\z)/i

      # A recorded version that is not the binary's.
      record Mismatch, name : String, recorded : String, current : String?

      class Changed < Error
        def initialize(path : String, mismatches : Array(Mismatch))
          details = mismatches.join("; ") do |mismatch|
            mismatch.current ? "#{mismatch.name} was #{mismatch.recorded}, is #{mismatch.current}" : "#{mismatch.name} (#{mismatch.recorded}) is not registered"
          end
          statements = mismatches.map { |mismatch| FUNCTIONS.includes?(mismatch.name) ? "REINDEX EXPRESSIONS;" : "REINDEX #{mismatch.name};" }.uniq!
          super("#{path}: indexes were built with other collation or text function versions (#{details}). " \
                "Add a migration with #{statements.join(" ") { |statement| "`#{statement}`" }} and run `punch db:migrate`", code: 1)
        end
      end

      # The collations the schema names, lowercased, without SQLite's own.
      def self.used(connection : Database::Driver::Connection) : Set(String)
        names = Set(String).new
        connection.query("SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL", Tuple.new) do |row|
          row.read(String).scan(COLLATE) { |match| names << (1..5).compact_map { |index| match[index]? }.first.downcase }
        end
        names.reject! { |name| SQLITE.includes?(name) }
        connection.query("SELECT sql FROM sqlite_schema WHERE type = 'index' AND sql IS NOT NULL", Tuple.new) do |row|
          sql = row.read(String)
          USES.each { |name, use| names << name if sql.matches?(use) }
        end
        names
      end

      # The collations a migration rebuilds with `REINDEX`, and Punch's text
      # functions when it rebuilds expression indexes. A bare `REINDEX`
      # rebuilds everything.
      def self.reindexed(sql : String) : Set(String)
        names = sql.scan(REINDEX).map { |match| (match[1]? || match[2]).downcase }.to_set
        names.concat(FUNCTIONS) if names.includes?("expressions") || sql.matches?(REINDEX_ALL)
        names << ALL if sql.matches?(REINDEX_ALL)
        names
      end

      # What `reindexed` holds for a bare `REINDEX`.
      ALL = "*"

      # The version of each collation in *collations* and of each text function.
      def self.versions(collations : Array(Text::Collation)) : Hash(String, String)
        current = collations.to_h { |collation| {collation.name, collation.version} }
        FUNCTIONS.each { |name| current[name] = FUNCTION_VERSION }
        current
      end

      def self.recorded(connection : Database::Driver::Connection) : Hash(String, String)
        versions = {} of String => String
        return versions unless table?(connection)

        connection.query("SELECT name, version FROM #{TABLE} ORDER BY name", Tuple.new) do |row|
          versions[row.read(String)] = row.read(String)
        end
        versions
      end

      # Recorded versions that differ from *collations*.
      def self.mismatches(connection : Database::Driver::Connection, collations : Array(Text::Collation)) : Array(Mismatch)
        current = versions(collations)
        recorded(connection).compact_map do |name, version|
          Mismatch.new(name, version, current[name]?) unless current[name]? == version
        end.sort_by!(&.name)
      end

      # Raises `Changed` when the indexes were built with other versions.
      def self.check(connection : Database::Driver::Connection, collations : Array(Text::Collation), path : String) : Nil
        mismatches = mismatches(connection, collations)
        raise Changed.new(path, mismatches) unless mismatches.empty?
      end

      # After a migration, inside its transaction: records the version of
      # every collation the schema now uses, and of those *reindexed*.
      # A changed version stays recorded until a migration reindexes it.
      def self.record(connection : Database::Driver::Connection, collations : Array(Text::Collation), reindexed : Set(String)) : Nil
        used = used(connection)
        current = versions(collations).select { |name, _| used.includes?(name) }
        return if current.empty? && !table?(connection)

        create_table(connection)
        recorded = recorded(connection)
        current.each do |name, current_version|
          version = recorded[name]?
          next if version == current_version || (version && !reindexed.includes?(name) && !reindexed.includes?(ALL))
          connection.exec("INSERT INTO #{TABLE} (name, version) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET version = excluded.version",
            {name, current_version})
        end
        # A collation the schema no longer uses has no indexes to protect.
        (recorded.keys - used.to_a).each { |name| connection.exec("DELETE FROM #{TABLE} WHERE name = ?", {name}) }
      end

      def self.create_table(connection : Database::Driver::Connection) : Nil
        connection.exec("CREATE TABLE IF NOT EXISTS #{TABLE} (name TEXT PRIMARY KEY, version TEXT NOT NULL) STRICT")
      end

      def self.table?(connection : Database::Driver::Connection) : Bool
        found = false
        connection.query("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?", {TABLE}) { |_| found = true }
        found
      end
    end
  end
end
