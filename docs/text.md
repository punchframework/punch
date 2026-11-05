# Text

Learn it in: [Text and Sort Order](guides/text-and-sort-order.md).

By default SQLite orders text by bytes: capitals come first and every non-ASCII initial comes last ("Ärger" after "zulu"); `LIKE`, `lower`, and `upper` only know ASCII letters. Punch fixes both at the database, and normalizes text at the boundary.

## Normalization

Text primitives (`Punch::NonEmptyString`, `Punch::Email`, `Punch::Slug`, your own) normalize to NFC when parsed (`docs/core-types.md`), so "é" typed as one character or as "e" plus an accent is one value. Equality and unique indexes then behave. Text that bypasses the primitives (a raw SQL literal) is stored as given.

## Collations

Declare the order in the schema:

```sql
CREATE TABLE customers (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL COLLATE de
) STRICT;

CREATE INDEX customers_by_name ON customers (name);
```

`ORDER BY name`, comparisons, and the index follow the collation. A query can name another one for a reader in another locale, `ORDER BY name COLLATE fr`; that query sorts without the index.

Punch registers its collations on every connection: the app's, the query generator's, spec databases, and the shell of `punch db:shell`. `punch db` lists them.

| Name | Language | Provider |
|---|---|---|
| `de`, `en`, `fr`, `it`, `nl`, `pt` | German, English, French, Italian, Dutch, Portuguese | Latin (Crystal) |
| `es` | Spanish; close, since ñ sorts as n | Latin (Crystal) |

The Latin provider compares in four levels; each decides only when the ones before are equal:

1. **Letters**, with case and accents folded away: `Ärger` sorts with `arger`, `ß` as `ss`, `Æ` as `ae`. Spaces come before punctuation and symbols, those before digits, digits before letters; letters of other scripts after Latin ones, by code point.
2. **Accents**: unaccented first (`apfel`, `äpfel`).
3. **Case**: lowercase first (`apfel`, `Apfel`).
4. **Bytes**, so only identical strings are equal. A unique index on a collated column is as strict as without the collation: `Café` and `cafe` are different values.

It is wrong where accented letters are letters of their own (Swedish, Danish, Norwegian, Polish, Czech). A collation's name is an interface: a later provider (ICU) can take over `de` without changing application code.

**Cost.** About 3.8 times the default order when sorting or indexing a whole column (100,000 names: 149 ms against 39 ms). Indexed lookups and pages compare only a few values.

**Changing a column's collation** needs a table rebuild, since SQLite cannot alter it in place: create the new table, copy the rows, drop the old one, rename (`reference/db/migrations/20261009090000_sort_customer_names.sql`). Foreign keys are off during a migration, so references by table name survive.

**Stock SQLite tools** (the system `sqlite3`, reporting tools) do not know Punch's collations and cannot sort or index collated columns. Use `punch db:shell`.

## Versions

A collation's rules can change (a new provider, new rules, a newer Unicode). An index built with the old rules is then out of order, and lookups and uniqueness go wrong without an error. So a collation never changes silently:

- Each collation has a version (`punch-latin-1/unicode-17.0.0`).
- `punch db:migrate` records the version of every collation the schema uses in `punch_collations`; `db/schema.sql` carries the rows.
- Opening a database file whose recorded version differs from the binary's fails with `Punch::Database::CollationVersions::Changed`, naming the collations.
- The fix is a migration that rebuilds the indexes, which the migrator records:

  ```sql
  -- db/migrations/20270101120000_reindex_de.sql
  REINDEX de;
  ```

  `punch db:migrate` refuses to run while a changed collation has no pending `REINDEX`.

`punch db PATH` shows each recorded version and whether it changed.

## Functions

`lower`, `upper`, and `like` are replaced on every connection:

| | SQLite | Punch |
|---|---|---|
| `lower('ÄRGER')` | `ÄRGER` | `ärger` |
| `upper('straße')` | `STRAßE` | `STRASSE` |
| `'Ärger' LIKE 'ä%'` | false | true |

`LIKE` ignores case in every script but not accents: `'Ärger' LIKE 'a%'` is false. `_` stands for one character, and `ESCAPE` works as in SQLite. To match user input literally, write `ESCAPE '\'` and pass the text as a `Punch::LikeText`, which the generator types the parameter as (`Customers::Search` in the reference app; docs/queries.md, "Filtering by text").

`lower`, `upper`, and `like` follow the Unicode tables of the Crystal release the app is built with, so they are versioned like collations (`punch-text-1/unicode-17.0.0`). When an index uses one, in its key or its `WHERE`, `punch db:migrate` records the version as `lower()`, `upper()`, or `like()` in `punch_collations`. After a Crystal upgrade with new Unicode data, or a change to Punch's rules, opening the database fails until a migration rebuilds those indexes:

```sql
-- db/migrations/20270101120000_reindex_expressions.sql
REINDEX EXPRESSIONS;
```

`REINDEX EXPRESSIONS` rebuilds every index on an expression or a virtual generated column. A partial index whose `WHERE` alone uses a function, on plain columns, is not among them: name it (`REINDEX tags_noted;`), or rebuild everything with a bare `REINDEX;`, which the migrator accepts for every version. A `STORED` generated column keeps the value it was written with; rewrite it in the same migration (`UPDATE tags SET name = name;`). `db:cost` counts each `REINDEX` as a scan.

Overriding `like` gives up SQLite's index use for prefix matches (`LIKE 'abc%'`), which needs the built-in function and `case_sensitive_like`. Real search moves to full-text search later.

## Custom collations

An app can add its own:

```crystal
reverse = Punch::Text::Collation.new("reverse", "1", ->(a : Bytes, b : Bytes) { b <=> a })
config = Punch::Database::Config.new(collations: Punch::Text::Collation::BUILTIN + [reverse])
```

The compare proc runs on whatever thread runs the query and must not raise; a failure is reported on standard error and the pair is ordered by bytes. Change the version whenever the order changes.

## Not yet

- ICU as a provider, and collations for languages with letters of their own.
- Accent-insensitive matching (`LIKE` that finds `Müller` for `mul`).
- Versions for functions used only in generated columns or `CHECK` constraints, which no index uses.
