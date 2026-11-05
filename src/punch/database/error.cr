module Punch
  class Database
    # A failure inside SQLite or the connection model. This is an exception:
    # SQL that does not prepare, a lock held past `busy_timeout`, or a full
    # disk are bugs or outages, not outcomes an operation returns. A unique
    # violation is a value, returned by the generated write that can cause
    # it (`Punch::Database::Violation`); every other constraint failure raises
    # `ConstraintError`.
    # The writer's queue stayed full for `Config#enqueue_timeout`: the
    # server answers 503 with `Retry-After` instead of waiting longer.
    class WriterBusy < Exception
    end

    class Error < Exception
      # SQLite's extended result code, such as 2067 for a UNIQUE violation.
      getter code : Int32
      getter sql : String?
      # Where in *sql* the error is, in bytes, if SQLite knows.
      getter offset : Int32?
      # SQLite's message alone, without the SQL.
      getter detail : String

      def initialize(message : String, @code : Int32 = 1, @sql : String? = nil, @offset : Int32? = nil, detail : String? = nil)
        @detail = detail || message
        super(message)
      end

      # The primary result code: the low byte of `code`.
      def primary_code : Int32
        code & 0xFF
      end

      # :nodoc:
      def self.build(message : String, code : Int32, sql : String, offset : Int32?) : Error
        text = offset ? "#{message} at byte #{offset} of: #{sql}" : "#{message} in: #{sql}"

        case code & 0xFF
        when 19   then ConstraintError.new(text, code, sql, offset, message)
        when 5, 6 then BusyError.new(text, code, sql, offset, message)
        else           Error.new(text, code, sql, offset, message)
        end
      end
    end

    # A constraint failed: UNIQUE, CHECK, NOT NULL, FOREIGN KEY, or a STRICT
    # column type.
    class ConstraintError < Error
    end

    # The database stayed locked longer than `busy_timeout`, usually by
    # another process.
    class BusyError < Error
    end

    # A statement of a multi-statement script failed. `position` is the byte
    # offset in the script; `line` and `column` count from 1.
    class ScriptError < Error
      getter position : Int32
      getter line : Int32
      getter column : Int32

      def initialize(detail : String, code : Int32, script : String, @position : Int32)
        before = script.byte_slice(0, position)
        @line = before.count('\n') + 1
        @column = before.size - (before.rindex('\n') || -1)
        super("#{detail} (line #{@line}, column #{@column})", code, script, position, detail)
      end
    end

    # A column did not hold the type the code reads it as.
    class ColumnError < Error
      getter column : String
      getter index : Int32

      def initialize(@column : String, @index : Int32, expected : String, detail : String?, sql : String)
        super("column #{index} (#{column}) is not #{expected}: #{detail} in: #{sql}", 20, sql)
      end
    end

    # A stored value did not parse into its column's domain type: bad data,
    # or a type that was tightened without an audit. Names the table,
    # column, and row ID, never the value.
    class RowError < Error
      getter table : String
      getter column : String
      getter row_id : Int64?
      # The `Invalid` code the domain type returned.
      getter reason : String
      # Where in a composite's document the value failed, such as
      # `$.lines[2].amount`; `nil` for a plain column.
      getter path : String?

      def initialize(@table : String, @column : String, @row_id : Int64?, type : String, @reason : String, @path : String? = nil)
        row = row_id ? "row #{row_id}" : "a row (its ID was not selected)"
        at = path.try { |where| " at #{where}" }
        super("#{table}.#{column} in #{row} does not parse as #{type}#{at}: #{reason}", 20)
      end
    end

    # The database directory is on a filesystem where WAL snapshots are not
    # reliable: refused at boot.
    class FilesystemError < Error
    end
  end
end
