module Punch
  class Database
    # The current row of a query. Read columns left to right with
    # `row.read(Int64)`, `row.read(String?)`, and so on.
    alias Row = Database::Driver::Row

    # What `Writer#exec` returns: the number of rows changed, and the row ID
    # of the last insert.
    alias ExecResult = Database::Driver::ExecResult

    # A value bound to a `?` placeholder.
    alias Value = Database::Driver::Value

    # An array bound to `carray(?)`: `WHERE id IN carray(?)` with
    # `Database::Values.new([1_i64, 2_i64])`. Elements are `Int64`,
    # `Float64`, `String`, or `Bytes`.
    alias Values = Database::Driver::Carray

    # Queries shared by `Reader` and `Writer`. Arguments bind to `?`
    # placeholders in order and must be `Nil`, `Bool`, `Int32`, `Int64`,
    # `Float64`, `String`, or `Bytes`; convert domain types where you bind
    # them. Anything else does not compile.
    module Queries
      # :nodoc:
      abstract def lease : Lease

      # Every row of *sql*, each turned into a value by the block. *name*
      # names the statement's span; generated queries pass theirs.
      def query_all(sql : String, *args : *T, name : String? = nil, & : Row -> R) : Array(R) forall T, R
        Queries.check_arguments(T)
        select_all(sql, args, name) { |row| yield row }
      end

      # Every row of *sql*, with its arguments in an array: for statements
      # assembled at run time, such as a query with declared clauses, whose
      # arguments depend on which clauses apply.
      def query_all(sql : String, *, args : Array(Value), name : String? = nil, & : Row -> R) : Array(R) forall R
        select_all(sql, args, name) { |row| yield row }
      end

      # The first row of *sql*, turned into a value by the block, or `nil`
      # if there is none.
      def query_one?(sql : String, *args : *T, name : String? = nil, & : Row -> R) : R? forall T, R
        Queries.check_arguments(T)
        select_first(sql, args, name) { |row| yield row }
      end

      # The first row of *sql*, with its arguments in an array, or `nil`.
      def query_one?(sql : String, *, args : Array(Value), name : String? = nil, & : Row -> R) : R? forall R
        select_first(sql, args, name) { |row| yield row }
      end

      private def select_all(sql : String, args : Enumerable, name : String?, & : Row -> R) : Array(R) forall R
        rows = [] of R
        probe = lease.probe(sql, name)
        begin
          lease.connection.query(sql, args) { |row| rows << yield row }
          ok = true
        ensure
          probe.finish(rows.size, ok == true)
        end
        rows
      end

      private def select_first(sql : String, args : Enumerable, name : String?, & : Row -> R) : R? forall R
        probe = lease.probe(sql, name)
        state = 0 # 1: a row was read, 2: done
        begin
          lease.connection.query(sql, args) do |row|
            state = 1
            value = yield row
            state = 2
            return value
          end
          state = 2
        ensure
          probe.finish(state > 0 ? 1 : 0, state == 2)
        end
        nil
      end

      # Yields every row of *sql* without collecting them.
      def query_each(sql : String, *args : *T, name : String? = nil, & : Row ->) : Nil forall T
        Queries.check_arguments(T)
        probe = lease.probe(sql, name)
        count = 0
        begin
          lease.connection.query(sql, args) do |row|
            count += 1
            yield row
          end
          ok = true
        ensure
          probe.finish(count, ok == true)
        end
      end

      # :nodoc:
      macro check_arguments(types)
        \{% for type, index in {{ types }}.type_vars %}
          \{% for member in type.union_types %}
            \{% unless %w(Nil Bool Int32 Int64 Float64 String Slice(UInt8) Punch::Database::Driver::Carray).includes?(member.stringify) %}
              \{% raise "SQL argument #{index + 1} is #{type}; bind Nil, Bool, Int32, Int64, Float64, String, Bytes, or Punch::Database::Values. Convert domain types where they are bound, such as `email.to_s` (lib/punch/docs/persistence.md)." %}
            \{% end %}
          \{% end %}
        \{% end %}
      end
    end
  end

  # Read access to a database: the only handle a Query receives. Everything
  # read through one Reader comes from one snapshot. Valid only inside the
  # block it was given to.
  struct Reader
    include Database::Queries

    # :nodoc:
    getter lease : Database::Lease

    # :nodoc:
    def initialize(@lease : Database::Lease)
    end
  end

  # Write access inside one `BEGIN IMMEDIATE` transaction: the handle a
  # Command receives. Reads through it see the transaction's own writes.
  # Valid only inside the block it was given to.
  struct Writer
    include Database::Queries

    # :nodoc:
    getter lease : Database::Lease

    # :nodoc:
    def initialize(@lease : Database::Lease)
    end

    # Runs a statement that returns no rows. Use `query_all` or `query_one?`
    # for `INSERT … RETURNING`.
    def exec(sql : String, *args : *T, name : String? = nil) : Database::ExecResult forall T
      Database::Queries.check_arguments(T)
      lease.exec(sql, args, name)
    end
  end
end
