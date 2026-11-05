# Evolving a Live App

Applies to Punch 0.1.

An app in production keeps changing. It gets new entities, its columns are added, renamed, and removed, its types get stricter, and its jobs and API change shape. Every one of these changes reaches a database full of rows, a queue full of jobs, and clients built against yesterday's API, while the release before it is still running. This guide walks the roster app from [Getting Started](getting-started.md) through the changes a live app goes through, says which check in `punch check` guards each one, and covers what to do when a deploy goes wrong.

After reading this guide, you will know:

- the one rule every change to a live app follows, and why;
- how to add an entity, a column, and a state to an app in production;
- how to rename or remove a column across three releases;
- how to tighten a type, change a job payload, change the API, rotate keys, and take a new collation version;
- what rolling back means when migrations only go forward;
- what to do when a migration fails at boot, or succeeds and does damage.

Before you start: you have read [Migrations](migrations.md) and [Deploying](deploying.md). The roster app from [Getting Started](getting-started.md) runs in production with its `members` table, and backups are on ([Backup and Restore](backup-and-restore.md)).

## Two releases share one database

A deploy starts the new release beside the old one, on the same database files ([Deploying](deploying.md#how-a-deploy-hands-over)). The new release applies its migrations at boot, before `/up` answers 200. For the few seconds until the old process stops, it serves requests against the new schema. Rolling back does the same in reverse: the older binary runs against migrations it does not know.

The database is not the only thing the two releases share. Jobs one release enqueued are run by the other. Links signed by one are checked by the other. Clients built against the old API keep calling the new one. So every change follows one rule:

> [!IMPORTANT]
> A release works with the schema, the stored data, the waiting jobs, the keys, and the API clients of the release before it.

A change that cannot keep that promise in one release is split across several, each of which can. `punch check` compares your branch with the main branch and fails on most changes that break the rule:

| What changes | What the previous release needs | The check |
|---|---|---|
| Schema | Every table and column its generated code names | `migrations` (cost and acknowledged rebuilds); review |
| Stored values | Every value parses into its types | `bin/<app> db:audit`, nightly and on demand |
| Job payloads | Every waiting job can be read | `payloads` |
| API | Every request a correct client sends still works | `openapi` |
| Keys | Everything the new release signs, it accepts | `punch keys:*` in three deploys |
| Collations | Indexes ordered by the rules it reads them with | `db:migrate` refuses until a `REINDEX` is pending |

The schema row is the one the checks cover least: `punch check` measures what a migration costs, but it does not know which columns the release before reads. That part is yours, and most of this guide is about it.

## Adding an entity

A new entity is the [Getting Started](getting-started.md) loop again: a migration that creates the table, `punch generate entity`, the columns, the queries, and the operations. Creating a table is instant, and the release before never names it, so a new entity needs one release.

For the roster, the club starts holding events, each with members attending:

```sql illustrative="a migration in the roster app"
-- db/migrations/20261101080000_create_events.sql
-- Events the club holds, and who attends them.
CREATE TABLE events (
  id         INTEGER PRIMARY KEY,
  title      TEXT    NOT NULL,
  starts_at  TEXT    NOT NULL,
  created_at TEXT    NOT NULL
) STRICT;

CREATE TABLE attendances (
  event_id  INTEGER NOT NULL REFERENCES events (id),
  member_id INTEGER NOT NULL REFERENCES members (id),
  PRIMARY KEY (event_id, member_id)
) STRICT;

-- An attendance by member, for a member's events and for the foreign key.
CREATE INDEX attendances_by_member ON attendances (member_id);
```

The foreign keys sit on the new table, so the existing `members` table does not change. New operations add routes and add to `openapi.json`, which is never a breaking change ([Building a JSON API](building-a-json-api.md#breaking-changes)).

The release before has no routes for the new operations, so during the handover a request for them that reaches the old process gets a 404.

## Adding a column

Adding a column is one release, when the release before can keep writing rows without it. Two facts make that work:

- A query that selects every column, `SELECT *`, reads columns left to right. `ADD COLUMN` adds at the end, so the old release reads the columns it knows and never sees the new one.
- The old release's `Table.insert` leaves the new column out, so the row gets the column's default, or `NULL`. Its `Table.update` sets only the columns it knows.

So a new column is either nullable or has a default. SQLite refuses `NOT NULL` without a default in `ADD COLUMN` anyway. The roster adds a phone number, which members may leave empty, and a newsletter choice, which is off until a member turns it on:

```sql illustrative="a migration in the roster app"
-- db/migrations/20261101090000_add_member_contact.sql
-- A phone number a member may give, and whether they want the newsletter.
ALTER TABLE members ADD COLUMN phone TEXT;
ALTER TABLE members ADD COLUMN newsletter INTEGER NOT NULL DEFAULT 0;
```

`members` is `STRICT`, so each `ADD COLUMN` is a scan: SQLite checks every row's types, about 60 ms per million small rows. `punch db:cost` shows it:

```console
$ punch db:cost
...
scan     20261101090000_add_member_contact.sql
  scan       1  ALTER TABLE members ADD COLUMN phone TEXT
                adds a column to a STRICT table: SQLite checks every row's types
  scan       2  ALTER TABLE members ADD COLUMN newsletter INTEGER NOT NULL DEFAULT 0
                adds a column to a STRICT table: SQLite checks every row's types
```

Then map the new columns in `app/members/columns.cr`, run `punch db:generate`, and use them:

```crystal illustrative="the roster's columns.cr after the migration"
# app/members/columns.cr
Punch.table "members", Members,
  id: Members::ID,
  name: Punch::NonEmptyString,
  email: Punch::Email,
  created_at: Time,
  phone: Punch::NonEmptyString,
  newsletter: Bool
```

The input of `Members::Create` gets the new fields too. Give them a default or make them nilable, `getter phone : Punch::NonEmptyString?` and `getter newsletter : Bool = false`, so that clients that do not send them keep working. A new required input field is a breaking change, and the `openapi` check says so.

A column with a rule across rows, such as a unique phone number, is a column first and a unique index second. `CREATE UNIQUE INDEX` reads every row, and fails if two rows already share a value. That is a migration that can fail in production while it passed in development ([A migration fails at boot](#a-migration-fails-at-boot)).

## Renaming or removing a column

Removing a column, or renaming one, takes away something the release before names. Its generated code lists every column of the table, `Table.find` and `Table.update` included, so once the column is gone, the old release fails on every read and write of that table: for a few seconds during the handover, and entirely after a rollback. Even a release that no longer uses the column in its own code still names it in its generated code.

So the change is split into three releases. A rename is "add the new column, move to it, remove the old one". The roster renames `name` to `display_name`:

**Release 1: add the new column, write both, read the new one.**

```sql illustrative="release 1 of a rename in the roster app"
-- db/migrations/20261101100000_add_member_display_name.sql
-- The name to show, which replaces `name` (dropped two releases later).
ALTER TABLE members ADD COLUMN display_name TEXT;
UPDATE members SET display_name = name;
```

Map `display_name` in `columns.cr`. It is nilable for now: rows that the release before adds during the handover do not have it. The Commands write both columns, `Table.insert(db, name: input.display_name, display_name: input.display_name, …)`, and the code reads `record.display_name || record.name`.

**Release 2: make the new column required, and stop writing the old one.**

```sql illustrative="release 2 of a rename in the roster app"
-- db/migrations/20261102090000_require_member_display_name.sql
-- Rows added by the release before during the handover have no display
-- name yet; copy theirs, then require one. `name` is no longer written.
UPDATE members SET display_name = name WHERE display_name IS NULL;
ALTER TABLE members ALTER COLUMN display_name SET NOT NULL;
ALTER TABLE members ALTER COLUMN name DROP NOT NULL;
```

After `punch db:generate`, `display_name` is no longer nilable, and `name` is. The code reads only `display_name` and writes `nil` into `name`. The release before still writes `name`, which is allowed, and still reads `display_name || name`, which still works.

The `UPDATE` comes first in the same file, so the rows the release before added since release 1 are copied before `SET NOT NULL` checks every row. Without it, the migration fails at boot on the first such row.

**Release 3: drop the old column.**

```sql illustrative="release 3 of a rename in the roster app"
-- db/migrations/20261103090000_drop_member_name.sql
-- `name` was replaced by `display_name`; nothing writes it any more.
-- rebuild: members
ALTER TABLE members DROP COLUMN name;
```

`DROP COLUMN` rewrites every row, so it holds the write lock while it runs, and `-- rebuild:` acknowledges that ([Migrations](migrations.md#what-a-migration-costs)).

Here is where Punch falls short today. Release 2 no longer uses `name`, but its generated code still names it, because `name` is still in the schema. When release 3 drops it, release 2 fails on `members` until it stops, and rolling back from release 3 to release 2 fails. A way to leave a column out of the generated code for one release, before dropping it, exists only for converting a column to an encrypted one (`from(:email, clear: true)`, [Queries: converting a plaintext column](../queries.md#converting-a-plaintext-column)). Until it exists for every column, choose one of two:

- **Keep the old column.** It is nullable and nothing writes it, so it costs only its space. Drop it once Punch can leave it out of generated code.
- **Drop it, knowing the cost.** Deploy release 3 when writes are rare, expect errors on `members` for the seconds of the handover, and do not roll back past it: roll forward instead.

Removing a column without a replacement is releases 2 and 3 alone: stop reading and writing it, making it nullable if it is not, then drop it.

## Tightening a type

Every value is parsed into its domain type when it is read. A stricter type, such as a name of at most 100 characters instead of any non-empty text, turns rows written before into read failures: `Punch::Database::RowError`, raised on every page that shows such a row. So a stricter type is checked against the data before it ships:

1. Change the type in `columns.cr` and in the inputs, and build the app.
2. Restore a copy of production into a scratch directory and run the new binary's audit on it:

   ```console
   $ PUNCH_STORAGE=/tmp/rehearsal bin/roster restore
   $ bin/roster db:audit /tmp/rehearsal/primary.db
   ```

   It names the table, the column, how many values do not parse, and the first row IDs, never the values ([Keeping SQL Safe and Fast](keeping-sql-safe-and-fast.md)).
3. Fix the rows it names, in a migration or with a Command, in a release before the stricter type.
4. Ship the stricter type once the audit is clean.

The audit also runs every night against production and shows its findings in the ops console, so a value that slipped in another way shows up there.

A stricter input type also accepts fewer requests, which is a breaking API change: the `openapi` check reports it.

## Adding a state

A new value in a stored enum, such as a member status `suspended` beside `active`, has the same problem as a removed column, from the other side. The release before cannot parse the new value, so every row that holds it fails to read there.

There are two ways to add a state:

- **Two releases.** Release 1 adds the value to the enum and handles it everywhere, but never writes it. Release 2 writes it. By then, every release that runs can read it.
- **A table of its own.** The state is a row in another table, and the store decides the state from both. The reference app's `Paid` is a sent invoice with a row in `invoice_payments`; its `status` column keeps the two values every release reads ([Domain Models](domain-models.md#the-store)).

The API side is separate: a new enum value in a response is a breaking change, since a client may handle every value it knew. The reference app raised its version from 0.1.0 to 0.2.0 when the invoice status gained `paid`.

## Changing a job payload

A job enqueued by one release is run by another, sometimes days later. `payloads.lock.json` records every job's payload, and the `payloads` check fails on a change that waiting jobs cannot follow ([Background Jobs](background-jobs.md#changing-a-payload)):

- Add a field with a default, or nilable: compatible, in one release.
- Add a required field, remove one, or change a type: raise the payload's version, and keep the old shape as a frozen type that converts itself to the new one.
- Delete a frozen type, or a job type, once `punch jobs:versions` shows nothing of it waiting in any environment.

A rollback needs nothing from you. An old binary only claims payload versions it can read, so it leaves the newer release's jobs waiting until that release is back.

## Changing the API

`openapi.json` is the app's promise to its clients. The `openapi` check compares it with the main branch and fails on a change that breaks a client that was correct before: a removed operation or response property, a new required input, a value no longer accepted ([Building a JSON API](building-a-json-api.md#breaking-changes)).

Most changes can be made compatible in the same way as a column: add the new field beside the old one, and remove the old one later, after clients have moved. When the break is the point, accept it and raise the version in `shard.yml`. Before 1.0, the minor version is enough: the reference app went to 0.3.0 when sending an invoice started to require an `Idempotency-Key`.

## Rotating keys

The key ring signs links and encrypts columns. A new key goes through three deploys, so that every running process already accepts what the other signs ([Credentials and Keys](credentials-and-keys.md#rotating-keys-without-breaking-links)):

1. `punch keys:rotate`: the new key is accepted everywhere, and signs nothing yet.
2. `punch keys:promote`: the new key signs, and the old one is still accepted. Then `bin/<app> db:encrypt`, or the nightly job, encrypts every row again under the new key.
3. `punch keys:retire ID`, once the longest-lived link signed with the old key has expired and `db:audit` shows no value under it.

Retiring early is the one step that cannot be undone: what the old key signed or encrypted no longer opens.

## Taking a new collation version

A Punch release can change a collation's rules. An index built with the old rules would then be out of order without any error, so the app refuses to open the database until a migration rebuilds those indexes ([Text and Sort Order](text-and-sort-order.md#when-a-collations-rules-change)):

```sql illustrative="the migration a changed collation asks for"
-- db/migrations/20261104090000_reindex_de.sql
-- Punch's de collation has new rules; rebuild its indexes.
REINDEX de;
```

The message names each collation that changed, so you meet this when you upgrade Punch, in development, not on deploy day. `REINDEX` reads every row of the collated columns, a scan.

## Rolling back

Rolling back is deploying the previous release's binary: `kamal rollback`, or `deploy/deploy.sh` with the old binary. The schema stays as it is. Migrations only go forward, so there is nothing to undo: the old binary runs against migrations it does not know, which `bin/<app> db:status` lists as `unknown` and which do not stop it.

That is why the rule at the top of this guide matters most on a bad day. A rollback works exactly when the new release's migrations kept the release before working. Everything else follows on its own: old binaries leave newer job payloads waiting, keys in their first step are accepted by both, and a compatible API is compatible in both directions.

Roll back when the new code is wrong and the data is fine. When the data is wrong, a rollback does not help: fix it forward, or restore ([A migration did damage](#a-migration-did-damage)).

## A migration fails at boot

A migration that passed in development can fail in production on data that development never had: a `CREATE UNIQUE INDEX` over values two rows share, a `SET NOT NULL` over a row without a value. Punch runs each migration in one transaction, so a failure undoes all of it. The boot stops with the file, line, and column, and `/up` never answers 200:

```text
db/migrations/20261101110000_index_member_phones.sql:2:1: UNIQUE constraint failed: members.phone
```

The proxy never switches to the new release: Kamal or `deploy.sh` reports the failed health check, and the old release keeps serving. Nothing in the database changed, and nothing needs to be rolled back.

First decide which is wrong: the data or the migration. Find the rows with `punch db:shell PATH` on a restored copy, or in the ops console. If two members share a phone number by mistake, the data is wrong, and the migration is right. If members of one family share a phone, the migration is wrong: phone numbers are not unique, and the index must never exist.

Either way, do not edit the failed migration. It is already applied in development and in every other environment where it passed, and Punch refuses to migrate a database whose applied migration changed.

**When the data is wrong, fix it in a migration that sorts before the failed one.** Pending migrations run in version order, so a later migration would never run: the failed one stops the boot first. Create one with `punch db:migration`, then rename its file to a version between the last migration production has and the failed one, such as `20261101105900_clear_shared_phones.sql`. What to do with the rows is a decision about your data: merge the members, or clear one phone number. Production runs the fix, then the failed migration. A development database that already has the failed migration runs the fix too, out of order, which is harmless for a data fix.

**When the migration is wrong, delete it and write its replacement.** Production never applied it, so it can go: delete the file, and write what should have been done in a new migration. Databases that applied the deleted migration keep its effect, and `db:status` lists it as `unknown`. So write the replacement to work whether or not the deleted one ran:

```sql illustrative="a replacement for a wrong migration in the roster app"
-- db/migrations/20261101120000_index_member_phones_for_lookup.sql
-- Replaces 20261101110000_index_member_phones, which was deleted: members
-- of one family share a phone, so phones are not unique. Databases where
-- it ran have its unique index.
DROP INDEX IF EXISTS members_by_phone;
CREATE INDEX members_by_phone_lookup ON members (phone);
```

Then recreate your development database with `punch db:migrate` on an empty one. `db/schema.sql` is written from the development database, so until then it still lists the deleted migration as applied, and the `schema` check fails. Where the deleted migration's effect cannot be undone this way, such as a dropped column in staging, restore that environment from its backup or recreate it.

Before you deploy again, rehearse: restore a copy of production into a scratch directory and run the new binary's migrations on it, the same way as for an audit:

```console
$ PUNCH_STORAGE=/tmp/rehearsal bin/roster restore
$ bin/roster db:migrate /tmp/rehearsal/primary.db
```

Rehearsing like this before every deploy that changes data is the cheapest way to never see a migration fail at boot.

## A migration did damage

A migration that succeeds and is wrong, such as an `UPDATE` without its `WHERE`, is replicated to the backup within a second, like any other write. There are two ways back:

- **Fix forward.** When the damage can be repaired from what is still in the database, write a new migration that repairs it, and deploy it. Nothing written since is lost. This is the usual way.
- **Restore to a point in time.** When the data is gone, restore to the second before the migration ran ([Backup and Restore](backup-and-restore.md#restoring-to-a-point-in-time)). Everything written after that second is gone from the restored files too; the replaced files are kept aside, for single rows you need back.

Before you start the app on restored files, install a release without the bad migration: the previous one, or a fixed one. The restored database does not have the migration, so the release that brought it would run it again at boot.

## Common mistakes

**Dropping or renaming a column in the release that stops using it.** The release before still names it in its generated code, so it fails between the migration and its own shutdown, and a rollback to it fails entirely. Add, move, and drop in separate releases ([Renaming or removing a column](#renaming-or-removing-a-column)).

**A new `NOT NULL` column without a default.** SQLite refuses the `ADD COLUMN`:

```text message=sqlite
Cannot add a NOT NULL column with default value NULL
```

Adding a default that is wrong for some rows only to get past it is worse: give the column a default that is true for every row, or add it nullable, fill it, and require it a release later.

**Writing a new enum value in the release that adds it.** The release before cannot parse the rows that hold it. Teach the value first, write it a release later.

**Editing a migration that failed in production.** It is applied in development, and probably elsewhere, which then refuses to migrate:

```text message=src/punch/migrations.cr
applied migrations were changed afterwards: 20261101110000_index_member_phones. Restore them and put the change in a new migration.
```

Fix the data in a migration that sorts before it, or, when the migration itself is wrong, delete it and write a replacement ([A migration fails at boot](#a-migration-fails-at-boot)).

**Restoring and starting the release that did the damage.** It runs the bad migration again. Install the previous release, or a fixed one, first.

**Retiring a key right after promoting it.** Every link it signed stops working, and every value it encrypted stops opening. Wait for the longest validity, and for `db:audit` to show nothing under it.

**Loosening a check to make a change pass.** Acknowledging a rebuild before checking the table's size, raising the API version without deciding the break is wanted, or deleting a frozen payload type while jobs of it wait each turns a check into a production failure. Do the honest fix the message names.

## Limits

- A plain column cannot yet be left out of the generated code while it still exists, so dropping or renaming one breaks the release before it for the seconds of the handover. Only a column being converted to an encrypted one has that step, `clear: true`.
- `punch check` does not know which columns the previous release names, so a migration that breaks it passes every check. Review each `DROP COLUMN`, `RENAME`, and changed enum against the release before.
- Migrations only go forward: there is no down migration, and a rollback never touches the schema.
- One machine: there is no standby to fail over to while a bad release is replaced.

## Rules

- Keep every release working with the schema, data, jobs, keys, and clients of the release before it. ([Two releases share one database](#two-releases-share-one-database))
- Add columns nullable or with a default. ([Adding a column](#adding-a-column))
- Rename or remove a column in three releases: add, move, drop. ([Renaming or removing a column](#renaming-or-removing-a-column))
- Audit a copy of production before shipping a stricter type. ([Tightening a type](#tightening-a-type))
- Teach a new stored value one release before writing it. ([Adding a state](#adding-a-state))
- Roll back the binary, never the schema. ([Rolling back](#rolling-back))
- Never edit a migration that ran anywhere. When one fails at boot, fix the data in a migration that sorts before it, or delete it and replace it if it is wrong. ([A migration fails at boot](#a-migration-fails-at-boot))
- After a restore, start a release without the bad migration. ([A migration did damage](#a-migration-did-damage))

## Reference

- [Migrations](../migrations.md): the files, how a migration runs, costs, and the binary's migrations.
- [Queries](../queries.md): `columns.cr`, generated records, converting a plaintext column, and `db:audit`.
- [Jobs](../jobs.md#payloads-across-deploys): payloads across deploys.
- [OpenAPI](../openapi.md#commands): `punch openapi` and `openapi:diff`.
- [Key ring](../keys.md#rotating): rotating keys.
- [Deployment](../deployment.md#migrations): migrations at boot and the handover.
- [Backup](../backup.md): restoring to a point in time.
