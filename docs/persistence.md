# Persistence

Learn it in: [SQLite in Punch](guides/sqlite-in-punch.md).

Punch stores data in SQLite files on local disk. This page covers the kernel: how a binary gets its SQLite, how connections are organized, and how code reads and writes. Migrations and generated queries build on it.

## The SQLite in every binary

SQLite 3.54.1 is vendored in `vendor/sqlite/` and compiled with Punch's options by `scripts/build-sqlite.sh` into `build/sqlite/`. Linking any Punch binary runs that script first. It compiles once, in about 20 seconds, and then only when the source or the script changes. The static library is found before the system's, so every binary carries the same engine, with `STRICT`, `RETURNING`, JSONB, and column metadata behaving the same everywhere. `punch db` shows the version and the compile options. Among them: `TRUSTED_SCHEMA=0`, so a schema can call only functions marked innocuous (Punch's are) and a crafted database file cannot run others through a trigger or view; `DEFAULT_DEFENSIVE=1`, so SQL cannot switch on `writable_schema` and corrupt a file; and files created with mode 0600. `serve` creates the storage directory with mode 0700.

The same build provides the shell: `punch db:shell PATH` runs SQLite's own shell, compiled from the vendored `shell.c` into the `punch` binary. It has no JSON mode of its own on the command line; inside the shell, `.mode json` gives JSON.

## Databases and connections

```crystal
databases = Punch::Databases.open("/var/lib/app", %w[primary])
databases.attach(server)                 # a health check per database; closed after the drain
router = Punch::Routing::Router.new(databases.primary)
```

Each database is one file with its own connections:

- **One writer connection**, owned by a fiber on its own thread. Write transactions queue on a channel and run one after another, each in `BEGIN IMMEDIATE`. Inside one process, writes never meet `SQLITE_BUSY`. A second process on the same file (a deploy handover, `punch jobs`) waits through `busy_timeout`.
- **A pool of read-only connections** (`query_only = ON`), one per thread of the default execution context and at least two. Each `read` is one read transaction, so every query inside it sees the same snapshot.

Settings, all optional, go in `Punch::Database::Config`:

| Setting | Default | |
|---|---|---|
| `readers` | threads of the default context, at least 2 | read connections |
| `checkout_timeout` | 5 s | how long `read` waits for a free reader |
| `queue_size` | 256 | writes waiting before `write` blocks |
| `enqueue_timeout` | 5 s | how long `write` waits for room in a full queue; then it raises `Database::WriterBusy`, which a request answers with 503 `database_busy` and `Retry-After` |
| `optimize_interval` | 1 hour | how often the writer runs `PRAGMA optimize` |
| `checkpoint_pages` | 1000 | WAL frames after which the writer checkpoints (below) |
| `pragmas` | see below | overrides, plain words only |
| `collations` | `Text::Collation::BUILTIN` | registered on every connection, with Punch's `lower`, `upper`, and `like` (`docs/text.md`) |
| `check_collations` | `true` | refuse a file whose indexes were built with other collation versions; off only for the migration commands |

Pragmas, in this order. `busy_timeout` always comes first, otherwise a second process fails while setting `journal_mode`. Readers skip `journal_mode`, `journal_size_limit`, and `secure_delete`.

```
busy_timeout = 5000, journal_mode = WAL, synchronous = NORMAL, foreign_keys = ON,
mmap_size = 134217728, journal_size_limit = 67108864, cache_size = 2000, temp_store = MEMORY,
secure_delete = ON
```

`secure_delete` zeroes what a write deletes or overwrites, freed pages included, so a deleted row or a cleared value does not stay readable in the file. It costs writes when pages are freed, such as when a table is dropped.

The pragma `wal_autocheckpoint` is refused: the writer checkpoints itself. Once a transaction leaves `checkpoint_pages` frames in the WAL, it runs a passive checkpoint after answering that write, and times it. Its queue depth, the WAL, and the checkpoints are metrics (`docs/metrics.md`). After an incomplete checkpoint (a reader still needed frames), the next waits for `checkpoint_pages` more frames. Replication with Litestream, which checkpoints too, is in `docs/backup.md`.

The writer runs `PRAGMA optimize = 0x10002` when it opens and `PRAGMA optimize` every hour and on close, each in its own `BEGIN IMMEDIATE` transaction.

### Limits

Every connection gets SQLite's run-time limits (`sqlite3_limit`) before its first statement, and ATTACH is off: no database can be attached, created, or written through ATTACH, so `ATTACH` and `VACUUM INTO` fail. Punch uses neither. The limits bound what one statement, value, or schema can cost. The defaults (`Punch::Database::Config::LIMITS`) leave wide margins over what Punch and the reference app use:

| Limit | Default | Bounds |
|---|---|---|
| `length` | 33,554,432 (32 MiB) | one string, blob, or row; 32 times the default request body |
| `sql_length` | 1,048,576 (1 MiB) | one statement; a migration counts statement by statement |
| `parser_depth` | 500 | the parser's stack for one statement (SQLite needs more than 50 only for deeply nested SQL) |
| `trigger_depth` | 32 | triggers firing triggers |
| `variable_number` | 1,000 | the highest parameter number, `?1000` |
| `schema` | 10,000 | tables, indexes, and triggers in one file; a file with more does not open |
| `trigger_steps` | 100 | statements in one trigger |
| `like_pattern_length` | 50,000 | a `LIKE` or `GLOB` pattern, in bytes (SQLite's default, kept because search terms become patterns) |

A value over a limit fails its statement with SQLite's error (`string or blob too big`, `variable number must be between ?1 and ?1000`). An app changes a database's limits in `app/setup.cr`; the others keep their defaults:

```crystal
# Invoices with scanned attachments of up to 100 MiB.
Punch::Database.limits "primary", length: 128 * 1024 * 1024
```

The names are the files of `serve`: `primary`, `cache`, `queue`, `ops`. A value above SQLite's compiled maximum is refused when the app starts. `punch config` shows each database's limits. They are part of the app, not of a deployment, so there is no environment variable for them. `punch db:shell` keeps SQLite's own limits.

### Filesystem check

WAL needs shared memory and file locks that network and virtual filesystems do not honour. On a folder shared into a virtual machine (virtiofs), read transactions saw inconsistent snapshots. `Database.open` and `Databases.open` check the directory with `statfs` and refuse NFS, SMB/CIFS, 9p, FUSE (which includes virtiofs and sshfs), Ceph, AFS, and similar, with a message naming the directory. `punch db PATH` shows the verdict for a file.

## Reading and writing

Operations receive a handle, never a database:

```crystal
def call(input : Input, db : Punch::Reader) : Result
  db.query_all(%q(SELECT id, name FROM customers WHERE name LIKE ? || '%' ESCAPE '\' LIMIT 20), Punch::Database.escape_like(input.prefix)) do |row|
    Customer.new(row.read(Int64), row.read(String))
  end
end

def call(input : Input, db : Punch::Writer) : Result
  db.exec("UPDATE invoices SET sent_at = ? WHERE id = ?", Time.utc.to_rfc3339, input.invoice_id.value)
  Sent.new
end
```

| Method | On | Returns |
|---|---|---|
| `query_all(sql, *args) { \|row\| … }` | Reader, Writer | an array of the block's values |
| `query_one?(sql, *args) { \|row\| … }` | Reader, Writer | the first row's value, or `nil` |
| `query_each(sql, *args) { \|row\| … }` | Reader, Writer | nothing; streams rows |
| `exec(sql, *args)` | Writer | `changes` and `last_insert_id` |

- **Arguments** bind to `?` in order and must be `Nil`, `Bool`, `Int32`, `Int64`, `Float64`, `String`, or `Bytes`. A domain type does not compile; convert it where you bind it.
- **Columns** are read left to right with `row.read(T)` for the same types, nilable for nullable columns. A column that holds something else raises `Punch::Database::ColumnError` with its name and index. Reading `Time` or a domain type does not compile: read the stored form and parse it.
- **A handle is valid only inside its block.** Keeping it longer raises.
- **A write commits when the block returns and rolls back when it raises.** The exception reaches the caller. Calling `write` inside a write raises instead of waiting forever. For a Command the framework also rolls back when its result is a failure (a rejection, a violation, a status from 400 on): a refused Command changes nothing (`docs/queries.md`, Violations).
- **Errors are exceptions**: `Punch::Database::Error` with SQLite's extended code, the SQL, and the byte offset of a syntax error. `ConstraintError` for UNIQUE, NOT NULL, CHECK, foreign keys, and STRICT types; `BusyError` when another process held the lock past `busy_timeout`. Generated writes return unique violations as values instead (`docs/queries.md`).

Generated queries (`docs/queries.md`) are built on these methods and replace most hand-written SQL calls.

**Tracing** (`docs/tracing.md`). Each `read` and `write` is a span below the current one, and each statement a span below that, named by `name:` when given (`db.query_all(sql, name: "Notes.recent") { … }`; generated queries pass theirs) or by its first keyword. Statements record their SQL text and row counts, never their arguments, and add to the totals on the request's wide event. A write records how long it waited for the writer (`punch.db.writer_wait_ms`).

## Testing

```crystal
Punch::Spec.database do |db|               # in memory, fresh for this example
  db.write { |writer| writer.exec("CREATE TABLE notes (body TEXT NOT NULL) STRICT") }
end

Punch::Spec.database(file: true) do |db|   # a file in a fresh temporary directory, with WAL
end
```

In-memory databases use SQLite's memdb VFS, so the writer and the readers share one database. Without WAL they take turns on one lock: fine for specs, not for load. `file: true` gives the production setup; the system's temporary directory must be on local disk. App specs use `Punch::Spec.db` instead: a fresh in-memory database per example with the app's schema (`docs/testing.md`).

## The driver interface

All SQLite access goes through `Punch::Database::Driver` in `src/punch/database/driver.cr`, implemented on crystal-db and crystal-sqlite3. No `DB::`, `SQLite3::`, or SQLite C binding appears anywhere else, and only that file and the shell binding require the shards. The Ameba rule `Punch/DriverTypes` enforces it. The interface also describes statements without running them (`Connection#shape`: result columns with their table and origin column, parameters, read-only), which the query generator uses.

Workarounds for upstream defects are marked `UPSTREAM` in the code, to be removed once fixed there.

## Inspecting

| Command | Shows |
|---|---|
| `punch db [--json]` | SQLite version, source ID, thread safety, compile options |
| `punch db PATH [--json]` | also the file: filesystem verdict, size, WAL size, journal mode, page counts, `user_version` |
| `punch db:shell PATH [SQL]` | the SQLite shell on that file; it does not create missing files |
