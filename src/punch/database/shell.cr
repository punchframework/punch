# The SQLite shell, compiled from the vendored `shell.c` with the same options
# as the library (scripts/build-sqlite.sh), its `main` renamed. Only the CLI
# requires this file, so other binaries do not link the shell.
{% begin %}
  @[Link(ldflags: "`{{ __DIR__.id }}/../../../scripts/build-sqlite.sh --ldflags` -lpunchsqliteshell -lsqlite3 -lm")]
  lib LibPunchSQLiteShell
    fun main = punch_sqlite_shell_main(argc : Int32, argv : UInt8**) : Int32
  end
{% end %}

module Punch
  class Database
    module Shell
      # Runs the shell with *args* (as for `sqlite3`) on this process's
      # terminal and returns its exit code. Its connections get Punch's
      # collations and text functions, so collated columns sort, compare,
      # and index as in the app.
      def self.run(args : Array(String)) : Int32
        Database::Driver.prepare_everywhere(Database.box(Text::Collation::BUILTIN))
        STDOUT.flush
        STDERR.flush
        argv = ["punch db:shell"].concat(args).map(&.to_unsafe)
        argv << Pointer(UInt8).null
        LibPunchSQLiteShell.main(args.size + 1, argv.to_unsafe)
      end
    end
  end
end

# Called by the shell once its `sqlite3_config` calls are done, in place of
# its own `sqlite3_initialize` (`SQLITE_SHELL_INIT_PROC`, set by
# scripts/build-sqlite.sh): registering an auto-extension before that point
# would initialize SQLite too early.
fun punch_sqlite_shell_init : Nil
  Punch::Database::Driver.install_everywhere
end
