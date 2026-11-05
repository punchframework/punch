module Punch
  class Database
    # SQLite's run-time limits on every connection Punch opens to one
    # database (`sqlite3_limit`), set before anything else runs on it. They
    # bound what one statement, value, or schema may cost; Punch and the
    # reference app stay far below each (measured 2026-11-01: statements up
    # to 644 bytes with 11 parameters, a parser stack that never outgrows
    # SQLite's first 50 entries, 52 schema objects, triggers of one step
    # and one level). `docs/persistence.md`, "Limits".
    #
    # An app changes them per database in `app/setup.cr`; the other values
    # keep their defaults:
    #
    # ```
    # Punch::Database.limits "primary", length: 64 * 1024 * 1024
    # ```
    struct Limits
      # Largest string, blob, or row, in bytes: 32 times the largest request
      # body by default (`HTTP::Config::DEFAULT_MAX_BODY_SIZE`).
      getter length : Int32
      # Longest SQL statement, in bytes. A migration's statements count one
      # by one, not the whole file.
      getter sql_length : Int32
      # Deepest parser stack one statement may need.
      getter parser_depth : Int32
      # Deepest nesting of triggers firing triggers.
      getter trigger_depth : Int32
      # Highest parameter number in a statement (`?NNN`).
      getter variable_number : Int32
      # Most tables, indexes, and triggers a database file may define; a file
      # with more does not open.
      getter schema : Int32
      # Most statements in one trigger.
      getter trigger_steps : Int32
      # Longest pattern `LIKE` and `GLOB` accept, in bytes. SQLite's default:
      # filters and search build patterns from request input, so a lower
      # value would turn long search terms into errors.
      getter like_pattern_length : Int32

      # SQLite's compiled maximum for each (`SQLITE_MAX_*`); `sqlite3_limit`
      # would lower a larger value to it without saying so.
      MAXIMUM = {
        length:              1_000_000_000,
        sql_length:          1_000_000_000,
        parser_depth:        2_500,
        trigger_depth:       1_000,
        variable_number:     32_766,
        schema:              10_000_000,
        trigger_steps:       65_000,
        like_pattern_length: 50_000,
      }

      def initialize(*, @length : Int32 = 32 * 1024 * 1024, @sql_length : Int32 = 1024 * 1024,
                     @parser_depth : Int32 = 500, @trigger_depth : Int32 = 32, @variable_number : Int32 = 1000,
                     @schema : Int32 = 10_000, @trigger_steps : Int32 = 100, @like_pattern_length : Int32 = 50_000)
        each do |name, value|
          unless 1 <= value <= MAXIMUM[name]
            raise ArgumentError.new("limit #{name} must be between 1 and #{MAXIMUM[name]}, not #{value}")
          end
        end
      end

      # A copy with the given limits changed, checked like `new`.
      def merge(*, length : Int32 = @length, sql_length : Int32 = @sql_length, parser_depth : Int32 = @parser_depth,
                trigger_depth : Int32 = @trigger_depth, variable_number : Int32 = @variable_number, schema : Int32 = @schema,
                trigger_steps : Int32 = @trigger_steps, like_pattern_length : Int32 = @like_pattern_length) : Limits
        Limits.new(length: length, sql_length: sql_length, parser_depth: parser_depth, trigger_depth: trigger_depth,
          variable_number: variable_number, schema: schema, trigger_steps: trigger_steps, like_pattern_length: like_pattern_length)
      end

      # Yields each limit's name and value, in a fixed order.
      def each(& : Symbol, Int32 ->) : Nil
        yield :length, length
        yield :sql_length, sql_length
        yield :parser_depth, parser_depth
        yield :trigger_depth, trigger_depth
        yield :variable_number, variable_number
        yield :schema, schema
        yield :trigger_steps, trigger_steps
        yield :like_pattern_length, like_pattern_length
      end
    end

    @@limits = {} of String => Limits

    # Changes the limits of the database *name* (`primary`, `cache`,
    # `queue`, `ops`) on every connection opened from now on; call it in
    # `app/setup.cr`. Unnamed limits keep their defaults (`Config::LIMITS`).
    def self.limits(name : String, **overrides) : Limits
      @@limits[name] = Config::LIMITS.merge(**overrides)
    end

    # The limits connections to the database *name* get.
    def self.limits_for(name : String) : Limits
      @@limits[name]? || Config::LIMITS
    end

    # Forgets every `limits` call (specs).
    # :nodoc:
    def self.reset_limits : Nil
      @@limits.clear
    end
  end
end
