# Migrations and `schema.sql`

Learn it in: [Migrations](guides/migrations.md), [Evolving a Live App](guides/evolving-a-live-app.md).

The schema changes through plain SQL files. Every run rewrites `db/schema.sql`, the one file that shows the whole database.

## Files

```
db/
  migrations/
    20261008153000_create_customers.sql
    20261009101500_create_invoices.sql
  schema.sql
```

- A migration is `db/migrations/<14-digit UTC timestamp>_<name>.sql`, created with `punch db:migration create_invoices`. Any other file in the folder is an error, apart from dotfiles and a README, so a typo cannot hide a migration.
- It holds any number of SQL statements. Punch runs them in one transaction; the file must not contain `BEGIN`, `COMMIT`, `ROLLBACK`, or `END`.
- **Migrations only go forward.** There is no down migration. In development, delete the database and migrate again. In production, a mistake is fixed by a new migration, or by a restore.
- **An applied migration is never edited.** Punch records each migration's SHA-256 and refuses to migrate while an applied one has changed.

```sql
-- db/migrations/20261009101500_create_invoices.sql
CREATE TABLE invoices (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers (id),
  total_cents INTEGER NOT NULL,
  sent_at TEXT
) STRICT;

CREATE INDEX invoices_by_customer ON invoices (customer_id);
```

## How a migration runs

Each migration runs on the database's writer as SQLite's procedure for schema changes prescribes:

1. `PRAGMA foreign_keys = OFF`, outside the transaction, so that rebuilding a referenced table (create new, copy, drop old, rename) does not cascade deletes.
2. `BEGIN IMMEDIATE`. Inside it, Punch checks the migration is still pending, so two processes migrating at once apply it once.
3. The statements, one by one.
4. `PRAGMA foreign_key_check`: any violation fails the migration.
5. A row in `punch_schema_migrations`: version, name, checksum, time. Then `COMMIT`, and foreign keys back on.

A failure rolls the whole migration back and raises `Punch::Migrations::Failed` with file, line, and column, such as `db/migrations/20261009101500_create_invoices.sql:4:3: no such table: main.customer`. Migrations before it stay applied.

Migrations hold the database's single write lock while they run, so a long one is a write outage. `punch db:cost` says what each statement costs (next section).

## What a migration costs

`punch db:cost` sorts every statement into one of three classes, by what it does on a large table:

| Class | Means | Statements |
|---|---|---|
| `instant` | Changes the schema only | `CREATE TABLE`, `CREATE VIEW`, `CREATE TRIGGER`; `DROP VIEW`, `DROP TRIGGER`; `RENAME TO`, `RENAME COLUMN`; `ALTER COLUMN ... DROP NOT NULL`, `DROP CONSTRAINT`; `ADD COLUMN` on a table that is not `STRICT`; `INSERT ... VALUES` |
| `scan` | Reads every row once and keeps the table | `CREATE INDEX`, `REINDEX`, `ANALYZE`; `ALTER COLUMN ... SET NOT NULL`, `ADD CHECK`; `ADD COLUMN` on a `STRICT` table, or with a `CHECK`, or generated and `NOT NULL`; `UPDATE`, `DELETE`, `INSERT ... SELECT`, `CREATE TABLE ... AS SELECT`; `DROP TABLE` and `DROP INDEX` (they free every page); anything Punch does not know |
| `rebuild` | Writes a new copy of every row | SQLite's 12-step procedure (create a new table, copy, drop the old one, rename); `DROP COLUMN` |

Only tables with rows count. Every table from before the migration has rows; so does one the migration filled from a query. Indexing or altering a table the same migration created is instant.

**`ADD COLUMN` on a `STRICT` table is a scan**, and Punch's tables are `STRICT`: SQLite then runs `pragma_quick_check` on the table, which reads every row to check its types (measured on 2026-10-13: about 60 ms per million small rows with a warm cache; a table that is not `STRICT` takes microseconds). A `CHECK` on an existing table no longer needs a rebuild: SQLite 3.53 has `ALTER TABLE ... ADD CHECK (...)`, which is a scan.

**A rebuild needs an acknowledgement in the file**, naming each table it rebuilds:

```sql
-- db/migrations/20261009090000_sort_customer_names.sql
-- SQLite cannot change a column's collation in place.
-- rebuild: customers
CREATE TABLE customers_new (...) STRICT;
INSERT INTO customers_new (...) SELECT ... FROM customers;
DROP TABLE customers;
ALTER TABLE customers_new RENAME TO customers;
```

A table whose ID type gains a public form (`public_id`, `docs/core-types.md`) needs `INTEGER PRIMARY KEY AUTOINCREMENT`, which SQLite cannot add in place: rebuild it the same way, and copy `id` with the rows. Copying the rows sets the table's `sqlite_sequence` entry to the highest rowid copied. Rows deleted from the end of the table before the rebuild are not known to it, so their rowids can come back once; if their public IDs are out, raise the entry above them in the same migration (`UPDATE sqlite_sequence SET seq = ... WHERE name = 'invoices'`).

`punch db:cost --check` fails on a rebuild without that line, and on a `-- rebuild:` line naming a table the migration does not rebuild. Before writing one, look for a change that keeps the table: a unique index instead of a `UNIQUE` constraint, a trigger, `ALTER COLUMN ... SET NOT NULL`, `ADD CHECK`.

`punch check` runs `punch db:cost --check --base <ref>`, with the same base as the OpenAPI diff (`--base`, else `origin/main` or `main`). Only migrations that the base revision does not have are checked: the others shipped already, and an applied migration is never edited (its checksum would change). Without a base revision, every migration is checked.

How it works: the migrations are replayed from the first in an in-memory database, one statement at a time. The schema before and after each statement says what it created, dropped, or renamed; a dropped table that exists again at the end of the migration was rebuilt. The statement's own words tell the rest (`ADD`, `DROP COLUMN`, `SET NOT NULL`).

Not counted: Punch's own work around every migration. `PRAGMA foreign_key_check` runs over the whole database before each commit, which reads every table that has a foreign key (measured: about 45 ms per million referencing rows).

```
$ punch db:cost
12 migrations: 8 instant, 2 scan, 2 rebuild
instant  20261008200000_create_customers.sql
rebuild  20261009090000_sort_customer_names.sql  rebuilds customers (acknowledged)
  rebuild   13  INSERT INTO customers_new (id, name, company_name, email, created_at)
                copies every row of customers into its new table
...
scan     20261012100000_add_user_locale.sql
  scan       3  ALTER TABLE users ADD COLUMN locale TEXT
                adds a column to a STRICT table: SQLite checks every row's types
```

The text shows the statements that are not instant. `--json` gives every statement: `{"base", "migrations": [{"version", "name", "file", "cost", "rebuilds", "acknowledged", "problems", "statements": [{"line", "sql", "cost", "table", "reason"}], "new"}]}`.

## Collation versions

The migrator records the version of each collation the schema uses (`punch_collations`, also in `db/schema.sql`). When a collation's rules change, a migration with `REINDEX <name>;` rebuilds its indexes; until one is pending, `punch db:migrate` refuses to run and the app refuses to open the database (`docs/text.md`). Punch's `lower`, `upper`, and `like` in indexes are versioned the same way, and rebuilt with `REINDEX EXPRESSIONS;`.

## `db/schema.sql`

Written by `punch db:migrate` from the migrated database: tables, indexes, views in creation order, and triggers, each as SQLite stores it, then the applied versions as an `INSERT`. The order is stable, so a diff shows exactly what a migration changed. Commit it with the migration, and never edit it.

Loading it gives a database with every migration recorded as applied, which is how specs start (`Punch::Spec.database(schema: "db/schema.sql")`).

`punch db:schema --check` builds a fresh database from the migrations in memory and compares its schema with the committed file. CI runs it, so a migration committed without its schema change, or a hand-edited schema file, fails the build.

## Commands

| Command | Does |
|---|---|
| `punch db:migration NAME` | Creates `db/migrations/<now>_<name>.sql` |
| `punch db:migrate [PATH]` | Applies pending migrations to the database at PATH, by default `$PUNCH_STORAGE/primary.db` (created if missing), and rewrites `db/schema.sql` when it changed |
| `punch db:status [PATH]` | Lists every migration as `applied`, `pending`, `changed`, or `unknown`; does not create a missing file |
| `punch db:schema [--check]` | Prints the schema the migrations produce, or compares it with `db/schema.sql` |
| `punch db:cost [--check] [--base REF]` | What each statement costs: instant, scan, or rebuild; `--check` fails on an unacknowledged rebuild in a migration REF does not have |

All take `--json`. Run them from the app's root. Without a path, they use the primary database in `PUNCH_STORAGE` (`docs/tooling.md`); `punch dev` migrates it on every change.

## In the application binary

The binary carries its migrations, so a deploy needs no source tree:

```crystal
MIGRATIONS = Punch::Migrations.embed("../db/migrations") # relative to this file, read at compile time

databases = Punch::Databases.open("/var/lib/app")
Punch::Migrations::Migrator.new(databases.primary, MIGRATIONS).migrate
```

A badly named file or a duplicate version in that folder is a compile error.

During a deploy handover, or after rolling back to an older binary, the database can hold migrations the running binary does not know. They show as `unknown` and do not stop it: write migrations so the previous release still works against the new schema (add first, remove a release later).

## API

| | |
|---|---|
| `Punch::Migrations.from_directory(dir = "db/migrations")` | Reads migrations at runtime |
| `Punch::Migrations.embed(dir)` | Reads them at compile time |
| `Punch::Migrations::Migrator.new(database, migrations)` | `#migrate` returns what it applied; `#status` and `#pending` report |
| `Punch::Migrations::Schema.dump(database)`, `.load(database, sql)` | The schema file |
