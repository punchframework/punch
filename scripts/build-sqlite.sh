#!/usr/bin/env bash
# Builds the vendored SQLite (vendor/sqlite) with Punch's compile options into
# build/sqlite/, from one source and one set of options:
#
# - libsqlite3.a, linked statically into every Punch binary;
# - libpunchsqliteshell.a, the SQLite shell with its `main` renamed, linked
#   into the `punch` binary for `punch db:shell`.
#
# With --ldflags, prints only the linker flags. Punch's `@[Link]` annotation
# runs it that way, so linking a Punch binary builds SQLite first if needed.
# Everything else goes to stderr.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

out=build/sqlite
mkdir -p "$out"

# Punch's options. Each one is a deliberate choice:
options=(
  -DSQLITE_THREADSAFE=1                # serialized; connections move between threads
  -DSQLITE_DQS=0                       # "x" is an identifier, never a string
  -DSQLITE_DEFAULT_MEMSTATUS=0         # no global allocation counters (a mutex per malloc)
  -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1   # synchronous=NORMAL in WAL mode
  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
  -DSQLITE_OMIT_DEPRECATED
  -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_OMIT_LOAD_EXTENSION         # no runtime extension loading
  -DSQLITE_USE_ALLOCA
  -DSQLITE_STRICT_SUBTYPE=1
  -DSQLITE_USE_URI=1                   # "file:/x?vfs=memdb": in-memory databases shared by connections
  -DSQLITE_ENABLE_COLUMN_METADATA      # result column origins for the query generator
  -DSQLITE_ENABLE_STAT4                # better plans for skewed data
  -DSQLITE_ENABLE_FTS5                 # full-text search
  -DSQLITE_ENABLE_MATH_FUNCTIONS
  -DSQLITE_ENABLE_DBSTAT_VTAB          # table and index sizes for the ops console
  -DSQLITE_ENABLE_CARRAY               # carray(?): typed arrays as one parameter (sqlite3_carray_bind_v2)
  -DSQLITE_ENABLE_PERCENTILE           # percentile(), median(), percentile_cont(), percentile_disc()
  -DSQLITE_TRUSTED_SCHEMA=0            # a schema may only use functions marked innocuous (Punch's are)
  -DSQLITE_DEFAULT_DEFENSIVE=1         # no writable_schema or other ways to corrupt a file from SQL
  -DSQLITE_DEFAULT_FILE_PERMISSIONS=0600 # databases, WAL, and shm readable by their owner only
)
cflags=(-O2 -fPIC "${options[@]}")

stale() { [ ! -f "$1" ] || [ vendor/sqlite/sqlite3.c -nt "$1" ] || [ vendor/sqlite/shell.c -nt "$1" ] || [ vendor/sqlite/SHA256SUMS -nt "$1" ] || [ "$0" -nt "$1" ]; }

# The sources must be the ones vendored (vendor/sqlite/SHA256SUMS), so a
# changed file is noticed before it reaches every binary. Only options
# GNU, BusyBox (Alpine), and macOS's shasum all have; the checker's lines
# are shown only when a file does not match.
verify_sources() {
  local result
  if command -v sha256sum >/dev/null; then result="$(cd vendor/sqlite && sha256sum -c SHA256SUMS 2>&1)"
  else result="$(cd vendor/sqlite && shasum -a 256 -c SHA256SUMS 2>&1)"; fi || { echo "$result"; return 1; }
}

if stale "$out/libsqlite3.a" || stale "$out/libpunchsqliteshell.a"; then
  verify_sources >&2 || { echo "punch: vendor/sqlite does not match vendor/sqlite/SHA256SUMS" >&2; exit 1; }
fi

if stale "$out/libsqlite3.a"; then
  echo "punch: building SQLite $(grep -m1 '#define SQLITE_VERSION ' vendor/sqlite/sqlite3.h | cut -d'"' -f2) (once, about 20 s)" >&2
  cc "${cflags[@]}" -c vendor/sqlite/sqlite3.c -o "$out/sqlite3.o"
  ar rcs "$out/libsqlite3.a.tmp" "$out/sqlite3.o"
  mv "$out/libsqlite3.a.tmp" "$out/libsqlite3.a"
  rm "$out/sqlite3.o"
fi

# The shell is compiled as a library: `main` becomes `punch_sqlite_shell_main`,
# the same renaming SQLite's own WebAssembly build applies, and it calls
# `punch_sqlite_shell_init` (src/punch/database/shell.cr) in place of
# `sqlite3_initialize`, so Punch can register its collations.
if stale "$out/libpunchsqliteshell.a"; then
  cc "${cflags[@]}" -Dmain=punch_sqlite_shell_main -DSQLITE_SHELL_INIT_PROC=punch_sqlite_shell_init -Ivendor/sqlite -c vendor/sqlite/shell.c -o "$out/shell.o"
  ar rcs "$out/libpunchsqliteshell.a.tmp" "$out/shell.o"
  mv "$out/libpunchsqliteshell.a.tmp" "$out/libpunchsqliteshell.a"
  rm "$out/shell.o"
fi

if [ "${1:-}" = "--ldflags" ]; then
  printf '%s' "-L$root/$out"
else
  echo "$out/libsqlite3.a" >&2
  echo "$out/libpunchsqliteshell.a" >&2
fi
