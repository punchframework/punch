require "db"
require "sqlite3"
require "c/sys/uio"
require "../text"

# The vendored SQLite: linking a Punch binary runs the build script, which
# compiles `vendor/sqlite` once and prints the directory to link from. It comes
# before the system's library, so `-lsqlite3` from crystal-sqlite3 resolves to
# the vendored static library (checked by `spec/database/driver_spec.cr`).
#
# Bindings crystal-sqlite3 0.23 lacks. They live here, next to the only
# code allowed to use them.
{% begin %}
  @[Link(ldflags: "`{{ __DIR__.id }}/../../../scripts/build-sqlite.sh --ldflags` -lm")]
  lib LibPunchSQLite
    alias Compare = (Void*, Int32, Void*, Int32, Void*) -> Int32
    alias Function = (LibSQLite3::SQLite3Context, Int32, LibSQLite3::SQLite3Value*) -> Nil
    alias Extension = (LibSQLite3::SQLite3, UInt8**, Void*) -> Int32
    alias WalHook = (Void*, LibSQLite3::SQLite3, UInt8*, Int32) -> Int32

    fun libversion = sqlite3_libversion : UInt8*
    fun sourceid = sqlite3_sourceid : UInt8*
    fun threadsafe = sqlite3_threadsafe : Int32
    fun compileoption_get = sqlite3_compileoption_get(n : Int32) : UInt8*
    fun extended_result_codes = sqlite3_extended_result_codes(db : LibSQLite3::SQLite3, onoff : Int32) : Int32
    fun extended_errcode = sqlite3_extended_errcode(db : LibSQLite3::SQLite3) : Int32
    fun error_offset = sqlite3_error_offset(db : LibSQLite3::SQLite3) : Int32
    fun create_collation_v2 = sqlite3_create_collation_v2(db : LibSQLite3::SQLite3, name : UInt8*, text_rep : Int32,
                                                          arg : Void*, compare : Compare, destroy : Void*) : Int32
    fun column_decltype = sqlite3_column_decltype(stmt : LibSQLite3::Statement, col : Int32) : UInt8*
    fun column_database_name = sqlite3_column_database_name(stmt : LibSQLite3::Statement, col : Int32) : UInt8*
    fun column_table_name = sqlite3_column_table_name(stmt : LibSQLite3::Statement, col : Int32) : UInt8*
    fun column_origin_name = sqlite3_column_origin_name(stmt : LibSQLite3::Statement, col : Int32) : UInt8*
    fun bind_parameter_count = sqlite3_bind_parameter_count(stmt : LibSQLite3::Statement) : Int32
    fun bind_parameter_name = sqlite3_bind_parameter_name(stmt : LibSQLite3::Statement, index : Int32) : UInt8*
    fun stmt_readonly = sqlite3_stmt_readonly(stmt : LibSQLite3::Statement) : Int32
    fun get_autocommit = sqlite3_get_autocommit(db : LibSQLite3::SQLite3) : Int32
    fun limit = sqlite3_limit(db : LibSQLite3::SQLite3, id : Int32, value : Int32) : Int32
    fun db_config = sqlite3_db_config(db : LibSQLite3::SQLite3, op : Int32, ...) : Int32
    fun context_db_handle = sqlite3_context_db_handle(context : LibSQLite3::SQLite3Context) : LibSQLite3::SQLite3
    fun carray_bind_v2 = sqlite3_carray_bind_v2(stmt : LibSQLite3::Statement, index : Int32, data : Void*, count : Int32,
                                                flags : Int32, destroy : Void*, destroy_arg : Void*) : Int32
    fun create_function_v2 = sqlite3_create_function_v2(db : LibSQLite3::SQLite3, name : UInt8*, n_arg : Int32, flags : Int32, app : Void*,
                                                        func : Function, step : Void*, final : Void*, destroy : Void*) : Int32
    fun value_type = sqlite3_value_type(value : LibSQLite3::SQLite3Value) : Int32
    fun value_bytes = sqlite3_value_bytes(value : LibSQLite3::SQLite3Value) : Int32
    fun result_text = sqlite3_result_text(context : LibSQLite3::SQLite3Context, text : UInt8*, bytes : Int32, destroy : Void*) : Nil
    fun result_null = sqlite3_result_null(context : LibSQLite3::SQLite3Context) : Nil
    fun result_error = sqlite3_result_error(context : LibSQLite3::SQLite3Context, message : UInt8*, bytes : Int32) : Nil
    fun get_auxdata = sqlite3_get_auxdata(context : LibSQLite3::SQLite3Context, n : Int32) : Void*
    fun set_auxdata = sqlite3_set_auxdata(context : LibSQLite3::SQLite3Context, n : Int32, data : Void*, destroy : Void* -> Nil) : Nil
    fun auto_extension = sqlite3_auto_extension(entry : Void*) : Int32
    fun initialize = sqlite3_initialize : Int32
    fun wal_hook = sqlite3_wal_hook(db : LibSQLite3::SQLite3, hook : WalHook, arg : Void*) : Void*
    fun wal_checkpoint_v2 = sqlite3_wal_checkpoint_v2(db : LibSQLite3::SQLite3, name : UInt8*, mode : Int32,
                                                      log : Int32*, checkpointed : Int32*) : Int32
  end
{% end %}

module Punch
  # The one place where Punch reaches SQLite. Implemented on crystal-db and
  # crystal-sqlite3; no `DB::`, `SQLite3::`, or `LibSQLite3` appears outside
  # this file, which the `Punch/DriverTypes` Ameba rule checks. Workarounds
  # for upstream defects are marked `UPSTREAM`, to be removed once fixed
  # there.
  module Database::Driver
    # What a statement parameter can be. Domain types convert to one of
    # these where they are bound.
    alias Value = Bool | Int32 | Int64 | Float64 | String | Bytes | Carray?

    # An array bound to `carray(?)`, SQLite's table of the values of one
    # parameter (`sqlite3_carray_bind_v2`): `id IN carray(?1)`. SQLite
    # copies the elements when it binds them.
    struct Carray
      getter values : Array(Int64) | Array(Float64) | Array(String) | Array(Bytes)

      def initialize(@values : Array(Int64) | Array(Float64) | Array(String) | Array(Bytes))
        if (texts = @values.as?(Array(String))) && texts.any?(&.includes?('\0'))
          # SQLite reads each text up to its first NUL.
          raise ArgumentError.new("a text bound to carray contains NUL")
        end
      end

      def size : Int32
        values.size
      end

      # What an empty array binds: never read, but not NULL.
      EMPTY = Pointer(Int64).malloc(1)

      # Binds the elements to parameter *index* of *statement*.
      # :nodoc:
      def bind(statement : LibSQLite3::Statement, index : Int32) : Int32
        # SQLite's copy of no elements fails to allocate; nothing to copy,
        # so an empty array binds as static (SQLITE_STATIC) data.
        return LibPunchSQLite.carray_bind_v2(statement, index, EMPTY.as(Void*), 0, 1, Pointer(Void).null, nil) if size == 0

        transient = Pointer(Void).new(UInt64::MAX) # SQLITE_TRANSIENT, (void*)-1: SQLite copies
        case values = @values
        in Array(Int64)
          LibPunchSQLite.carray_bind_v2(statement, index, values.to_unsafe.as(Void*), values.size, 1, transient, nil)
        in Array(Float64)
          LibPunchSQLite.carray_bind_v2(statement, index, values.to_unsafe.as(Void*), values.size, 2, transient, nil)
        in Array(String)
          pointers = values.map(&.to_unsafe)
          LibPunchSQLite.carray_bind_v2(statement, index, pointers.to_unsafe.as(Void*), values.size, 3, transient, nil)
        in Array(Bytes)
          vectors = values.map { |bytes| LibC::Iovec.new(iov_base: bytes.to_unsafe.as(Void*), iov_len: LibC::SizeT.new(bytes.size)) }
          LibPunchSQLite.carray_bind_v2(statement, index, vectors.to_unsafe.as(Void*), values.size, 4, transient, nil)
        end
      end
    end

    # The SQLite version linked into this binary.
    def self.version : String
      String.new(LibPunchSQLite.libversion)
    end

    def self.source_id : String
      String.new(LibPunchSQLite.sourceid)
    end

    def self.threadsafe : Int32
      LibPunchSQLite.threadsafe
    end

    def self.compile_options : Array(String)
      options = [] of String
      index = 0
      while (option = LibPunchSQLite.compileoption_get(index)) && !option.null?
        options << String.new(option)
        index += 1
      end
      options
    end

    # The rows changed by a write, and the row ID of the last insert.
    record ExecResult, changes : Int64, last_insert_id : Int64

    # One result column of a prepared statement. `table` and `origin` name
    # the column it comes from, `nil` for an expression.
    record Column, name : String, declared_type : String?, database : String?, table : String?, origin : String?

    # A prepared statement's shape, without running it: for the query
    # generator and `punch db`.
    record Shape, columns : Array(Column), parameters : Array(String?), read_only : Bool

    # A collation: compares two UTF-8 strings like `<=>`. Runs on whatever
    # thread runs the query, and must not raise.
    alias Compare = Proc(Bytes, Bytes, Int32)

    # Calls the boxed `Compare` that `create_collation_v2` hands back.
    COLLATION_TRAMPOLINE = ->(arg : Void*, len1 : Int32, p1 : Void*, len2 : Int32, p2 : Void*) do
      begin
        Box(Compare).unbox(arg).call(Bytes.new(p1.as(UInt8*), len1, read_only: true),
          Bytes.new(p2.as(UInt8*), len2, read_only: true))
      rescue ex
        # Raising into C would unwind through SQLite. A failing collation is
        # a bug: report it loudly and order the pair by bytes.
        STDERR.puts "punch: collation raised: #{ex.inspect_with_backtrace}"
        Bytes.new(p1.as(UInt8*), len1, read_only: true) <=> Bytes.new(p2.as(UInt8*), len2, read_only: true)
      end
    end

    # SQLite's `lower`, `upper`, and `like` fold ASCII only; these replace
    # them with `Punch::Text`. Deterministic and innocuous, so SQLite may
    # use them in indexes, views, and triggers.
    FUNCTION_FLAGS = 0x1 | 0x800 | 0x200000 # SQLITE_UTF8 | DETERMINISTIC | INNOCUOUS
    # SQLITE_TRANSIENT: SQLite copies the result before the call returns.
    TRANSIENT = Pointer(Void).new(UInt64::MAX)
    NULL_TYPE = 5

    LOWER = ->(context : LibSQLite3::SQLite3Context, _count : Int32, values : LibSQLite3::SQLite3Value*) do
      Database::Driver.text_result(context, values[0]) { |text| Text.lower(text) }
    end

    UPPER = ->(context : LibSQLite3::SQLite3Context, _count : Int32, values : LibSQLite3::SQLite3Value*) do
      Database::Driver.text_result(context, values[0]) { |text| Text.upper(text) }
    end

    # `like(pattern, text)` and `like(pattern, text, escape)`: what
    # `text LIKE pattern [ESCAPE escape]` calls.
    LIKE = ->(context : LibSQLite3::SQLite3Context, count : Int32, values : LibSQLite3::SQLite3Value*) do
      begin
        pattern, text = Database::Driver.text_value(values[0]), Database::Driver.text_value(values[1])
        escape = count == 3 ? Database::Driver.text_value(values[2]) : ""
        if pattern.nil? || text.nil? || escape.nil?
          LibPunchSQLite.result_null(context)
        elsif escape.size > 1 || (count == 3 && escape.empty?)
          message = "ESCAPE expression must be a single character"
          LibPunchSQLite.result_error(context, message, message.bytesize)
        elsif pattern.bytesize > LibPunchSQLite.limit(LibPunchSQLite.context_db_handle(context), Database::Driver::LIMIT_LIKE_PATTERN_LENGTH, -1)
          # The connection's limit, which SQLite's own `like` enforces.
          message = "LIKE or GLOB pattern too complex"
          LibPunchSQLite.result_error(context, message, message.bytesize)
        else
          tokens = Database::Driver.like_tokens(context, pattern, escape[0]?)
          LibSQLite3.result_int(context, tokens && Text.like?(tokens, text) ? 1 : 0)
        end
      rescue ex
        Database::Driver.function_error(context, ex)
      end
      nil
    end

    # `sqlite3_limit` categories (`SQLITE_LIMIT_*`) and `sqlite3_db_config`
    # options Punch sets.
    LIMIT_IDS = {
      length:              0,
      sql_length:          1,
      like_pattern_length: 8,
      variable_number:     9,
      trigger_depth:       10,
      parser_depth:        12,
      schema:              13,
      trigger_steps:       14,
    }
    LIMIT_ATTACHED                =    7
    LIMIT_LIKE_PATTERN_LENGTH     =    8
    DBCONFIG_ENABLE_ATTACH_CREATE = 1020
    DBCONFIG_ENABLE_ATTACH_WRITE  = 1021

    # The pattern's tokens, kept with the statement while its pattern
    # argument stays the same (`sqlite3_set_auxdata`), so a scan does not
    # take the pattern apart once per row. They live in C memory, which
    # SQLite frees: header (escape, count or -1 for a pattern that
    # matches nothing), then the characters.
    # :nodoc:
    def self.like_tokens(context : LibSQLite3::SQLite3Context, pattern : String, escape : Char?) : Indexable(Char)?
      key = escape.try { |char| char.ord.to_u32 + 1 } || 0_u32
      kept = LibPunchSQLite.get_auxdata(context, 0).as(UInt32*)
      if !kept.null? && kept[0] == key
        return if kept[1] == UInt32::MAX

        return Slice.new((kept + 2).as(Char*), kept[1].to_i32, read_only: true)
      end

      tokens = Text.like_tokens(pattern, escape)
      size = tokens.try(&.size) || 0
      copy = LibC.malloc(sizeof(UInt32) * (size + 2)).as(UInt32*)
      unless copy.null?
        copy[0] = key
        copy[1] = tokens ? size.to_u32 : UInt32::MAX
        tokens.try { |chars| (copy + 2).as(Char*).copy_from(chars.to_unsafe, size) }
        # SQLite may free it at once; only *tokens* is used from here on.
        LibPunchSQLite.set_auxdata(context, 0, copy.as(Void*), ->(data : Void*) { LibC.free(data) })
      end
      tokens
    end

    # :nodoc:
    def self.text_value(value : LibSQLite3::SQLite3Value) : String?
      return if LibPunchSQLite.value_type(value) == NULL_TYPE

      text = LibSQLite3.value_text(value)
      String.new(text, LibPunchSQLite.value_bytes(value))
    end

    # :nodoc:
    def self.text_result(context : LibSQLite3::SQLite3Context, value : LibSQLite3::SQLite3Value, & : String -> String) : Nil
      text = text_value(value)
      if text
        result = yield text
        LibPunchSQLite.result_text(context, result, result.bytesize, TRANSIENT)
      else
        LibPunchSQLite.result_null(context)
      end
    rescue ex
      function_error(context, ex)
    end

    # Raising into C would unwind through SQLite: the statement fails
    # with the message instead.
    # :nodoc:
    def self.function_error(context : LibSQLite3::SQLite3Context, ex : Exception) : Nil
      message = "punch: #{ex.message || ex.class.name}"
      LibPunchSQLite.result_error(context, message, message.bytesize)
    end

    # Registers the boxed collations and the text functions on a raw
    # handle: every Punch connection, and every connection the shell opens.
    # :nodoc:
    def self.install(handle : LibSQLite3::SQLite3, collations : Hash(String, Void*)) : Int32
      collations.each do |name, box|
        code = LibPunchSQLite.create_collation_v2(handle, name, 1, box, COLLATION_TRAMPOLINE, Pointer(Void).null)
        return code unless code == 0
      end
      {"lower" => {LOWER, 1}, "upper" => {UPPER, 1}, "like" => {LIKE, 2}}.each do |name, (function, arguments)|
        code = LibPunchSQLite.create_function_v2(handle, name, arguments, FUNCTION_FLAGS, nil, function, nil, nil, nil)
        return code unless code == 0
      end
      code = LibPunchSQLite.create_function_v2(handle, "like", 3, FUNCTION_FLAGS, nil, LIKE, nil, nil, nil)
      code
    end

    @@extension_collations = {} of String => Void*

    # The collations `install_everywhere` registers; they must stay alive.
    def self.prepare_everywhere(collations : Hash(String, Void*)) : Nil
      @@extension_collations = collations
    end

    # Initializes SQLite and installs the prepared collations and the text
    # functions on every connection opened in this process from now on,
    # through SQLite's auto-extension mechanism: for `punch db:shell`,
    # whose connections Punch does not open.
    def self.install_everywhere : Nil
      LibPunchSQLite.initialize
      entry = ->(handle : LibSQLite3::SQLite3, _error : UInt8**, _api : Void*) do
        Database::Driver.install(handle, @@extension_collations)
      end
      code = LibPunchSQLite.auto_extension(entry.pointer)
      STDERR.puts "punch: cannot register Punch's collations in the shell (#{code})" unless code == 0
    end

    # Opens a connection to *path* with crystal-sqlite3. *path* may be a URI
    # filename (`file:/name?vfs=memdb`), which the vendored build accepts.
    def self.open(path : String) : Connection
      raw = ::SQLite3::Connection.new(::DB::Connection::Options.new,
        ::SQLite3::Connection::Options.new(filename: path))
      LibPunchSQLite.extended_result_codes(raw.to_unsafe, 1)
      Connection.new(raw)
    rescue ::DB::ConnectionRefused
      # UPSTREAM crystal-sqlite3 0.23 replaces the cause with a bare
      # ConnectionRefused. Open again with the C API to recover the message.
      raise Database::Error.new("cannot open #{path}: #{diagnose_open(path)}", code: 14)
    end

    private def self.diagnose_open(path : String) : String
      flags = ::SQLite3::Flag::READWRITE | ::SQLite3::Flag::CREATE | ::SQLite3::Flag::URI
      code = LibSQLite3.open_v2(path, out handle, flags, nil)
      message = handle.null? ? "out of memory" : String.new(LibSQLite3.errmsg(handle))
      LibSQLite3.close_v2(handle) unless handle.null?
      code == 0 ? "the connection setup failed" : message
    end

    # A pool of connections, each set up by *setup* when it opens.
    class Pool
      def initialize(path : String, size : Int32, checkout_timeout : Time::Span, &setup : Connection -> Nil)
        # retry_delay 0: crystal-db would otherwise sleep 0.2 s before its
        # first attempt whenever no connection is idle. Punch checks out
        # with `using_connection`, which does not retry, so this is belt and
        # braces. UPSTREAM crystal-db 0.14.
        options = ::DB::Pool::Options.new(initial_pool_size: size, max_pool_size: size, max_idle_pool_size: size,
          checkout_timeout: checkout_timeout.total_seconds, retry_attempts: 1, retry_delay: 0.0)
        @db = ::DB::Database.new(::DB::Connection::Options.new, options) do
          connection = Database::Driver.open(path)
          setup.call(connection)
          @lock.synchronize { @opened << connection.raw }
          connection.raw.as(::DB::Connection)
        end
      end

      @lock = Mutex.new
      @opened = [] of ::SQLite3::Connection

      def using(& : Connection -> T) : T forall T
        raw = begin
          @db.checkout
        rescue ex : ::DB::PoolTimeout
          raise Database::Error.new("no connection free: #{ex.message}", code: 5)
        end
        begin
          yield Connection.new(raw.as(::SQLite3::Connection))
        ensure
          raw.release
        end
      end

      # Closes every connection. Call it once no fiber reads any more.
      def close : Nil
        # UPSTREAM crystal-db 0.14 (and master): `Pool#close` iterates its
        # connections while each `close` removes itself from that list, so
        # every second connection stays open. Close them from our own list.
        @lock.synchronize { @opened.dup }.each(&.close)
        @db.close
      end
    end

    # The number of frames in a connection's WAL after its last commit
    # (`Connection#watch_wal`), written on the connection's thread.
    class WalFrames
      getter value = Atomic(Int32).new(0)
    end

    # One SQLite connection. Not safe for two fibers at once: Punch's
    # connection model gives each connection to one fiber at a time.
    struct Connection
      # :nodoc:
      getter raw : ::SQLite3::Connection

      def initialize(@raw : ::SQLite3::Connection)
      end

      def exec(sql : String, args : Enumerable) : ExecResult
        statement = prepared(sql)
        begin
          result = statement.exec(args: args)
          ExecResult.new(result.rows_affected, result.last_insert_id)
        rescue ex : ::SQLite3::Exception
          # UPSTREAM crystal-sqlite3 0.23: after a failed step,
          # sqlite3_finalize returns that error again, so closing the cached
          # statement later raises from `close`. Resetting clears it.
          LibSQLite3.reset(statement.to_unsafe)
          raise Database::Driver.error(ex, @raw, sql)
        end
      end

      def exec(sql : String) : ExecResult
        exec(sql, Tuple.new)
      end

      def query(sql : String, args : Enumerable, & : Row ->) : Nil
        prepared(sql).query(args: args) do |result_set|
          row = Row.new(result_set, sql)
          while row.next?
            yield row
          end
        end
      rescue ex : ::SQLite3::Exception
        raise Database::Driver.error(ex, @raw, sql)
      end

      # Runs every statement in *script*, one after another, and yields the
      # byte offset where each one started after it ran. A failure raises
      # `Database::ScriptError` with the byte offset of the error in
      # *script*: SQLite's own position for a syntax error, otherwise the
      # start of the failing statement.
      def exec_script(script : String, & : Int32 ->) : Nil
        handle = @raw.to_unsafe
        base = script.to_unsafe
        offset = 0
        while offset < script.bytesize
          start = Database::Driver.skip_blank(script, offset)
          # The length includes the string's terminating NUL: SQLite then
          # applies `sql_length` to each statement, not to the rest of the
          # script.
          code = LibSQLite3.prepare_v2(handle, base + start, script.bytesize - start + 1, out statement, out tail)
          if code != 0
            position = LibPunchSQLite.error_offset(handle)
            raise script_error(script, start + Math.max(position, 0))
          end
          offset = (tail - base).to_i32
          next if statement.null? # only whitespace or comments left
          begin
            loop do
              step = LibSQLite3.step(statement)
              break if step == 101                                 # SQLITE_DONE
              raise script_error(script, start) unless step == 100 # SQLITE_ROW
            end
          ensure
            LibSQLite3.finalize(statement)
          end
          yield start
        end
      end

      private def script_error(script : String, position : Int32) : Database::ScriptError
        handle = @raw.to_unsafe
        Database::ScriptError.new(String.new(LibSQLite3.errmsg(handle)), LibPunchSQLite.extended_errcode(handle), script, position)
      end

      # A single value from the first row of *sql*, as text, or `nil`.
      def scalar_text(sql : String) : String?
        query(sql, Tuple.new) do |row|
          return row.read(String | Int64 | Float64 | Nil).try(&.to_s)
        end
        nil
      end

      # The shape of *sql*: columns with their origins, and parameters.
      def shape(sql : String) : Shape
        # Prepared, never run: the query generator's view of a query.
        handle = prepared(sql).to_unsafe # ameba:disable Punch/SQLText
        columns = Array.new(LibSQLite3.column_count(handle)) do |index|
          Column.new(
            name: String.new(LibSQLite3.column_name(handle, index)),
            declared_type: Database::Driver.string?(LibPunchSQLite.column_decltype(handle, index)),
            database: Database::Driver.string?(LibPunchSQLite.column_database_name(handle, index)),
            table: Database::Driver.string?(LibPunchSQLite.column_table_name(handle, index)),
            origin: Database::Driver.string?(LibPunchSQLite.column_origin_name(handle, index)))
        end
        parameters = Array.new(LibPunchSQLite.bind_parameter_count(handle)) do |index|
          Database::Driver.string?(LibPunchSQLite.bind_parameter_name(handle, index + 1))
        end
        Shape.new(columns, parameters, LibPunchSQLite.stmt_readonly(handle) != 0)
      end

      # SQLite's plan for *sql*, as `EXPLAIN QUERY PLAN` gives it: each step's
      # ID, its parent's ID, and its text. Parameters stay unbound.
      def query_plan(sql : String) : Array({Int64, Int64, String})
        steps = [] of {Int64, Int64, String}
        # The query generator's view of a query from the app's files, never run.
        query("EXPLAIN QUERY PLAN #{sql}", Tuple.new) do |row| # ameba:disable Punch/SQLText
          id, parent, _, detail = row.read(Int64), row.read(Int64), row.read(Int64), row.read(String)
          steps << {id, parent, detail}
        end
        steps
      end

      # Registers the boxed collations (name to a boxed `Compare`) and the
      # text functions on this connection. The caller keeps the boxes alive
      # as long as the connection.
      def install(collations : Hash(String, Void*)) : Nil
        code = Database::Driver.install(@raw.to_unsafe, collations)
        raise Database::Error.new("cannot register collations and text functions", code: code) unless code == 0
      end

      # Sets SQLite's run-time *limits* on this connection and turns ATTACH
      # off: no database may be attached, and none created or written
      # through ATTACH. Punch never attaches; SQL that tries fails.
      def harden(limits : Database::Limits) : Nil
        handle = @raw.to_unsafe
        limits.each do |name, value|
          LibPunchSQLite.limit(handle, LIMIT_IDS[name], value)
          unless LibPunchSQLite.limit(handle, LIMIT_IDS[name], -1) == value
            raise Database::Error.new("SQLite refused the limit #{name} = #{value}", code: 1)
          end
        end
        LibPunchSQLite.limit(handle, LIMIT_ATTACHED, 0)
        {DBCONFIG_ENABLE_ATTACH_CREATE, DBCONFIG_ENABLE_ATTACH_WRITE}.each do |option|
          code = LibPunchSQLite.db_config(handle, option, 0, Pointer(Int32).null)
          raise Database::Error.new("cannot turn off ATTACH (#{option})", code: code) unless code == 0
        end
      end

      # Keeps the number of frames in the WAL in *frames* after each commit,
      # and stops SQLite's automatic checkpoint: SQLite's own is a WAL hook,
      # which this one replaces, so the owner must checkpoint (`checkpoint`).
      # The caller keeps *frames* alive as long as the connection.
      def watch_wal(frames : WalFrames) : Nil
        LibPunchSQLite.wal_hook(@raw.to_unsafe, ->(arg : Void*, _db : LibSQLite3::SQLite3, _name : UInt8*, pages : Int32) {
          arg.as(WalFrames).value.set(pages)
          0
        }, frames.as(Void*))
      end

      # A passive checkpoint of the main database: copies what it can
      # without waiting for readers. Returns the frames in the WAL and how
      # many of them are now in the database file; fewer means a reader
      # still needs older pages.
      def checkpoint : {Int32, Int32}
        log = checkpointed = 0
        code = LibPunchSQLite.wal_checkpoint_v2(@raw.to_unsafe, nil, 0, pointerof(log), pointerof(checkpointed))
        raise Database::Error.new("checkpoint failed", code: code) unless code == 0
        {log, checkpointed}
      end

      # Whether a transaction is open on this connection.
      def in_transaction? : Bool
        LibPunchSQLite.get_autocommit(@raw.to_unsafe) == 0
      end

      def close : Nil
        @raw.close
      end

      private def prepared(sql : String) : ::SQLite3::Statement
        @raw.fetch_or_build_prepared_statement(sql).as(::SQLite3::Statement)
      rescue ex : ::SQLite3::Exception
        raise Database::Driver.error(ex, @raw, sql)
      end
    end

    # The current row of a query. Columns are read left to right.
    struct Row
      def initialize(@result_set : ::DB::ResultSet, @sql : String)
      end

      # :nodoc:
      def next? : Bool
        @result_set.move_next
      end

      # Reads the next column as *type*: `Int64`, `Int32`, `Float64`,
      # `String`, `Bytes`, `Bool`, or a union of them with `Nil`.
      def read(type : T.class) : T forall T
        {% for member in T.union_types %}
          {% unless %w[Int64 Int32 Float64 String Slice(UInt8) Bool Nil].includes?(member.stringify) %}
            {% raise "Row#read: cannot read #{member} from SQLite. Read Int64, Int32, Float64, String, Bytes, or Bool (nilable for nullable columns), and parse domain types from those (lib/punch/docs/persistence.md)." %}
          {% end %}
        {% end %}
        index = @result_set.next_column_index
        begin
          @result_set.read(T)
        rescue ex : ::DB::ColumnTypeMismatchError | TypeCastError | OverflowError
          raise Database::ColumnError.new(column(index), index, T.to_s, ex.message, @sql)
        end
      end

      # The name of column *index*.
      def column(index : Int32) : String
        @result_set.column_name(index)
      end

      def column_count : Int32
        @result_set.column_count
      end
    end

    # :nodoc:
    # The offset of the first byte at or after *offset* that is not
    # whitespace or part of a comment.
    def self.skip_blank(script : String, offset : Int32) : Int32
      bytes = script.to_slice
      while offset < bytes.size
        byte = bytes[offset]
        if byte.unsafe_chr.ascii_whitespace?
          offset += 1
        elsif byte == '-'.ord && bytes[offset + 1]? == '-'.ord
          offset = (script.byte_index('\n', offset) || bytes.size - 1) + 1
        elsif byte == '/'.ord && bytes[offset + 1]? == '*'.ord
          offset = (script.byte_index("*/", offset + 2).try(&.+(2))) || bytes.size
        else
          break
        end
      end
      offset
    end

    # :nodoc:
    def self.string?(pointer : UInt8*) : String?
      pointer.null? ? nil : String.new(pointer)
    end

    # :nodoc:
    def self.error(ex : ::SQLite3::Exception, raw : ::SQLite3::Connection, sql : String) : Database::Error
      code = LibPunchSQLite.extended_errcode(raw.to_unsafe)
      offset = LibPunchSQLite.error_offset(raw.to_unsafe)
      Database::Error.build(ex.message || "SQLite error", code, sql, offset >= 0 ? offset : nil)
    end
  end
end

# UPSTREAM crystal-sqlite3 0.23 has no binding for carray: binds a
# `Carray` like its own types.
class SQLite3::Statement
  private def bind_arg(index, value : Punch::Database::Driver::Carray)
    check value.bind(to_unsafe, index)
  end
end
