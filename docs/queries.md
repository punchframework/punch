# Queries

Learn it in: [Named Queries and Generated Code](guides/named-queries.md), [Keeping SQL Safe and Fast](guides/keeping-sql-safe-and-fast.md), [Column Encryption and Blind Indexes](guides/column-encryption.md).

Punch has no ORM. Queries are SQL in `.sql` files, and `punch db:generate` turns them into typed Crystal: one method per query, a row type per result, and a record with find, insert, update, and delete for every mapped table. The generated files are committed, so every database call can be read, grepped, and reviewed in a diff.

```
db/schema.sql                        the schema, written by punch db:migrate
app/billing/invoices/columns.cr      which columns of the entity's tables hold which domain types
app/billing/invoices/records.gen.cr  generated: a Record and Table per table mapped there
app/billing/invoices/queries.sql     named queries
app/billing/invoices/queries.gen.cr  generated: Billing::Invoices::Queries
```

## Named queries

```sql
-- name: ForCustomer :many
-- Invoices of one customer, newest first.
SELECT id, number, total_cents, sent_at
FROM invoices
WHERE customer_id = :customer_id
ORDER BY created_at DESC
LIMIT :limit;

-- name: MarkSent :one
UPDATE invoices SET sent_at = :now
WHERE id = :id AND sent_at IS NULL
RETURNING id, sent_at;
```

```crystal
rows = Billing::Invoices::Queries.for_customer(db, customer_id: customer.id, limit: 20)
rows.first.sent_at # => Time?
```

- **Header:** `-- name: Name :kind`. The name is CamelCase; the method is its snake_case form.
- **Kinds:** `:one` returns the first row or `nil`, `:many` an array, `:exec` nothing, `:execrows` the number of rows changed. Writes that return rows use `RETURNING` with `:one` or `:many`.
- **Parameters** are named (`:customer_id`, also `@name` and `$name`) and become keyword arguments. A parameter used twice is passed once. `?` is refused.
- **Comment lines** right after the header document the method. A comment between queries belongs to no query.
- **Behaviour modules:** `-- include Billing::Invoices::Invoice::Due` in the header includes that module in the query's `Row`, so a list row shares a rule with a model; the compiler checks the row has the fields the module needs (`docs/models.md`).
- **One statement per query.** Transaction statements are refused: a `Writer` is one transaction already.
- **The module comes from the path:** `app/billing/invoices/queries.sql` holds `Billing::Invoices::Queries`. Query files live under `app/` or `src/`, in snake_case directories.
- **The handle:** a query that only reads takes `Punch::Reader | Punch::Writer`; one that writes takes `Punch::Writer`, so a Query cannot call it.

Every query is prepared against `db/schema.sql` in the same SQLite the app links. A wrong column, table, or syntax fails here with SQLite's message and the file, line, and column. All mistakes of a run are reported together, and nothing is written.

```
app/billing/invoices/queries.sql:3:8: query ForCustomer: no such column: numbr
```

## Types

The generator derives each type; it asks for an annotation only where it cannot.

- **Result columns** that come straight from a table take the column's type and nullability. Columns on the optional side of a `LEFT JOIN` are nilable. An `INTEGER PRIMARY KEY` is never `NULL`.
- **Expressions** are typed by rules: `count`, `total`, `sum`/`min`/`max`/`avg` (nilable, since they are `NULL` over no rows), `coalesce`/`ifnull`, `CASE` and `iif`/`if` (nilable without a last value for when no condition holds), `CAST`, arithmetic, `||`, `EXISTS`, date and JSON functions, string functions (`concat` is never `NULL`; `concat_ws`, `octet_length`, and `unistr` are `NULL` when their first argument is; `timediff` is a nilable `String`), and scalar subqueries (always nilable).
- **Parameters** take the type of what they are compared with, inserted into, or assigned to; `LIMIT` and `OFFSET` take `Int64`; `LIKE` and `||` take `String`. A parameter that may be `NULL`, as the first argument of `coalesce` or `ifnull` compared with a column, takes that column's type, nilable: `WHERE id > coalesce(:after, 0)` gives `after : ID?`, an optional cursor. So does a parameter compared with `IS [NOT] DISTINCT FROM`, which treats `NULL` as a value: `WHERE parent_id IS NOT DISTINCT FROM :parent` gives `parent : ID?`.
- **Arrays** bind as one parameter to `carray`, SQLite's table of an array's values, and take the compared column's type: `WHERE id IN carray(:ids)` gives `ids : Array(Customers::ID)` (below).
- **Domain types carry through:** a parameter compared with `invoices.customer_id` is a `Customers::ID`, and `max(created_at)` of a `Time` column is a `Time?`. Arithmetic, `sum`, and string functions return plain values.
- **Annotations** for the rest, in the header: `-- column cents: Int64`, `-- param ids: String`. Allowed are `Int64`, `Float64`, `String`, `Bytes`, `Bool`, and `Time`, nilable with `?`. An annotation for a column or parameter the query does not have is an error.
- **`RIGHT` and `FULL JOIN`** are refused unless every column is annotated: their nullability is not derived.

Some columns come out nilable although they cannot be `NULL`, such as `sum` within a non-empty `GROUP BY` group. An annotation tightens them.

### Array parameters

```sql
-- name: ByIds :many
SELECT id, name FROM customers WHERE id IN carray(:ids);
```

```crystal
Billing::Customers::Queries.by_ids(db, ids: [a, b, c]) # ids : Array(Billing::Customers::ID)
```

- The elements take the type of the column before `IN` (or `NOT IN`), domain types included, and bind in its stored form: integers as `INT64`, text as `TEXT`, blobs as `BLOB`, floats as `DOUBLE`. SQLite copies them when they are bound; the SQL text stays the same whatever the number of elements.
- An empty array matches no rows.
- At most `Punch::Stored::ARRAY_MAX` (10,000) elements. The query's result includes `Punch::Invalid`, which it returns as `too_many` (with `max`) for a longer array, before it runs: `Array(ByIds::Row) | Punch::Invalid`. Return it as a rejection at the input's field, or cap the input's array beforehand.
- Compared with an encrypted column, an array is refused, as `IN` is; compared with a blind index, it binds the hashes of every element under every key (below).
- `carray(:param)` anywhere but after `IN` is refused: its type would be unknown. Array parameters are not supported yet in queries with declared clauses or pages.
- Hand-written SQL binds `Punch::Database::Values.new(array)` to `carray(?)`; elements are `Int64`, `Float64`, `String` (without NUL), or `Bytes`.

## Filters and sorting: declared clauses

A list with optional filters or a choice of order is one query. Each optional condition is a `-- when` line and each order an `-- order` line, written where they apply in the statement:

```sql
-- name: Search :many
SELECT i.id, i.number, i.total_cents, i.status, c.name AS customer_name
FROM invoices i
JOIN customers c ON c.id = i.customer_id
WHERE i.account_id = :account_id
-- when status:       AND i.status = :status
-- when customer_id:  AND i.customer_id = :customer_id
-- when q:            AND c.name LIKE '%' || :q || '%' ESCAPE '\'
-- when unsent:       AND i.sent_at IS NULL
-- order issued:      ORDER BY i.issued_on, i.id
-- order amount:      ORDER BY i.total_cents, i.id
LIMIT :limit OFFSET :offset;
```

```crystal
filter = Queries::Search::Filter.new(status: "sent", unsent: false)
Queries.search(db, account_id: account.id, limit: 20, offset: 0, filter: filter, order: :amount, direction: :desc)
```

- **`Search::Filter`** has one field per `when` clause, named after it. A clause with a parameter is on when its field is not `nil`; the field has the parameter's type, nilable (`customer_id : Customers::ID?`). A clause without one is a `Bool` toggle, on when `true`.
- **`Search::Order`** is an enum with one member per `order` line; the first is the default. The sort is a fixed piece of SQL chosen by the enum, never a column name from a request.
- **`direction:`** (`Punch::Database::Direction`, `asc` by default, `desc`) reads the chosen order as written or backwards: `desc` reverses every term (`ORDER BY total_cents DESC, id DESC`; `NULLS FIRST` becomes `NULLS LAST`), so a table can sort either way by any of its orders. An order is written ascending in its first term, so `asc` and `desc` say what they mean; later terms may go either way (`ORDER BY total, id DESC` reverses to `total DESC, id`). The enum parses from a query string as `asc` or `desc`.
- **`Filter` is a `Punch::Input`:** `Search::Filter.from_query(params)` parses it from a query string, with the usual rejections.
- **The file is still SQL:** clause lines are comments, so pasted into `punch db` it runs as the unfiltered, unsorted query.
- **Generated:** the statement in pieces (`SQL_1`, `WHEN_STATUS`, `ORDER_NEWEST`, …) and a method that joins the fixed pieces with the clauses switched on. Every value goes through a bound parameter.
- **Where the lines go:** a `when` line where its condition belongs, after the `WHERE`, `HAVING`, or `ON` condition it extends; the `order` lines where the `ORDER BY` belongs, after `GROUP BY` and `HAVING`.

### A filter in the domain's terms: an enum field

When a filter is one of the app's own choices rather than a column's value, name its enum in the header and write one clause per member:

```sql
-- name: Page :page
-- param status: Billing::Invoices::Invoice::Status
SELECT …
FROM invoices
LEFT JOIN invoice_payments ON invoice_payments.invoice_id = invoices.id
WHERE invoices.organization_id = :organization_id
-- when status = draft: AND invoices.status = 'draft'
-- when status = sent:  AND invoices.status = 'sent' AND invoice_payments.invoice_id IS NULL
-- when status = paid:  AND invoice_payments.invoice_id IS NOT NULL
GROUP BY invoices.id
ORDER BY invoices.id
```

- **`Filter#status`** is `Billing::Invoices::Invoice::Status?`: `nil` lists every state, a member switches on its clause. A query string names the member in snake_case (`?status=paid`); anything else is rejected with `invalid_choice`.
- **The compiler checks the members:** the generated method is a `case … in` over the enum, so a member without a clause, or a clause for a name that is not a member, does not compile. The message points at the generated file, whose comment names the query's line.
- **A member's clause takes no parameter** (the member chooses it) and follows the rules of any `when` clause. One field's member clauses go on consecutive lines, and a field is either one clause with a parameter or one clause per member.
- Use it where a single `= :status` cannot say what the member means, as here, where *paid* is a payment rather than a status, or where the app's enum and the stored text differ.

### Filter objects

`Filter` is the filter object: a value that narrows a query, built from a request or in code. Two habits keep it one:

- **The operation's input holds it**, as one field, so the operation, the page, its filter form, and a spec agree on what narrows the list:

  ```crystal
  struct Input
    include Punch::Input

    getter filter : Queries::Page::Filter = Queries::Page::Filter.new
    getter after : Queries::Page::Cursor?
  end
  ```

  A query string carries it in brackets, `?filter[status]=paid&filter[customer_id]=3`, as a form body carries a nested input; OpenAPI lists it as one `filter` parameter with `style: deepObject` (`docs/openapi.md`). A link writes it the same way (`IndexPage.href(filter: input.filter, after: page.next_after)`), and `v.filter_form` shows and sends it (`docs/views.md`, "Filter forms").
- **Spec the query with a filter directly**, without the operation or a request: `Queries.page(db, organization_id: organization, filter: Queries::Page::Filter.new(status: :paid), limit: 10)` (`reference/spec/billing/invoice_queries_spec.cr`).

### Filtering by text

User text is a bound value like any other; the pattern is built in SQL around it, so the statement's text never changes:

```sql
-- when q: AND customers.name LIKE '%' || :q || '%' ESCAPE '\'
```

```crystal
filter = Queries::Page::Filter.new(q: Punch::LikeText.new(text))
```

A `%` or `_` in the text would act as a wildcard: `50%` would match `500`. That widens nothing beyond the query's other conditions, so it is not an injection, but it is not what the person typed. Hence the types:

- **A `LIKE` whose pattern holds a parameter says `ESCAPE '\'`**; the generator refuses one without it, pointing at the `LIKE`.
- **That parameter, and the `Filter` field of its `-- when` clause, is a `Punch::LikeText`**, not a `String`, so passing a `String` does not compile. A `LikeText` holds the text as typed (`value`, which links and forms write back) and escapes it when bound (`\`, `%`, `_` get a `\` in front). It is a domain primitive: the filter object reads it from `filter[q]` like any other field, and OpenAPI lists it as a string. `LikeText.new(text)` makes one from text you hold.
- **A screen that offers wildcards on purpose** says so: `Punch::LikeText.pattern(text)` binds the text as it is. A request cannot produce one; only code does.
- **Full-text search** (`AND docs MATCH :q` on an FTS5 table) types its parameter as `Punch::FtsPhrase` the same way: the text is quoted as one phrase, so `OR`, `NOT`, `*`, and parentheses are words. `Punch::FtsPhrase.syntax(text)` is the opt-out for a screen that offers the search syntax.
- A parameter that feeds a `LIKE` or `MATCH` and is used elsewhere in the query is refused (it would be bound escaped there too); use two parameters.

`Punch::Database.escape_like` and `.fts_phrase` remain for SQL you write by hand (`db.query_all` in `docs/persistence.md`); generated queries never need them.

Never build the pattern, or any SQL, from the text in Crystal; `Punch/SQLText` enforces this (see "SQL text is never built from values" below).

Rules the generator checks:

| Rule | Why |
|---|---|
| A `when` clause starts with `AND`, and has no `OR` outside parentheses | A clause only narrows; `AND a OR b` would let in rows the rest of the condition excludes |
| The `WHERE`, `HAVING`, or `ON` condition a clause extends has no `OR` outside parentheses | `WHERE owner_id = :owner OR shared` followed by a clause would not narrow the shared rows; write `WHERE (owner_id = :owner OR shared)`. A query without a condition writes `WHERE true` |
| At most one parameter per clause, named like the clause, used nowhere else | The parameter is the filter field; split a range into two clauses (`issued_from`, `issued_to`) |
| `order` lines are consecutive, each `ORDER BY …`, without parameters | One place where the order goes |
| An order's first term is ascending (no `DESC`) | `direction: :desc` reads it backwards, so the direction's name is true |
| Clauses only in queries that read (`:one`, `:many`, `:page`) | A write states its conditions as parameters |
| No parameter named `filter`, `order`, `direction`, `args`, or `io` | The generated method uses these names |

Each clause line is one line. The generator prepares the query as written, each clause alone, every clause with the first order (which also types the parameters), every clause with each other order, and every clause with each order read backwards; a mistake inside a clause is reported at its file line and column. With *n* clauses and *m* orders a query has up to 2^n × 2m statements at run time, each prepared once per connection.

For a condition that needs a join, use `EXISTS (SELECT 1 FROM … WHERE …)` inside the clause. Conditions combined with `OR` across filters need a clause of their own. Plain SQL remains possible: `(:status IS NULL OR status = :status)` is a query like any other.

`punch db:generate --json` lists each query's `filter` fields with types and locations, its `orders`, and how many statements it prepared.

## Pages: keyset pagination

A list shown a page at a time is a `:page` query. Its order, the statement's own `ORDER BY` or its `-- order` lines, is the keyset: a page continues after the last row's sort values, never at an offset, so rows added or removed meanwhile neither repeat nor go missing, and a deep page costs what the first does.

```sql
-- name: Page :page
SELECT * FROM customers
WHERE organization_id = :organization_id
-- when q: AND name LIKE :q || '%' ESCAPE '\'
-- order created: ORDER BY id
-- order name: ORDER BY name, id
```

```crystal
page = Queries.page(db, organization_id: actor.organization_id, order: input.order, direction: input.direction, after: input.after, limit: 50)
page.rows        # => Array(Customers::Record), at most 50
page.next_after  # => Queries::Page::Cursor?, nil on the last page
```

- **The method** takes `after : Page::Cursor?` and `limit : Int32 | Punch::PageSize` besides the query's own parameters, `filter:`, and `order:`, and returns `Punch::Paged(Row, Page::Cursor)`: the rows (it is `Enumerable`) and `next_after`. It reads one row more than `limit`, so `next_after` is `nil` exactly on the last page; an empty page never follows a full one. A `limit` below 1 raises.
- **`Punch::PageSize`** is the page size of an input: `getter limit : Punch::PageSize = Punch::PageSize.of(50)`, 1 to 100. The bounds are written once: a request outside them is rejected with `out_of_range` (`min`, `max`), OpenAPI lists `minimum` and `maximum` beside the default, and a form's number control gets `min` and `max`. Pass it to the method as it is (`limit: input.limit`). An app that wants other bounds writes its own primitive with a `json_schema` and passes its `value`.
- **`Page::Cursor`** is a domain primitive: an opaque token (base64url of a JSON array of the sort values, and the order's name when there are several), so an input takes it as a field (`getter after : Queries::Page::Cursor?`) and a result returns it as text. A token that is not a cursor of this query is rejected with `invalid_cursor`. It is not signed: it only says where a page starts, and the query's conditions still decide which rows anyone sees. When a sort column holds a public ID (`docs/core-types.md`), its rowid would count records, so the cursor is sealed: AES-256-GCM under a key derived from `public_id_key`. Such a query accepts only sealed tokens (`Page::Cursor.sealed?`).
- **A cursor continues its own order.** It carries the order and direction it was made in, and the method uses them when `after` is given: `order:` and `direction:` beside a cursor are ignored. Each order has a condition per direction.
- **A cursor holds the position, not the filter.** A link to the next page repeats the filter next to `after` (`IndexPage.href(filter: input.filter, after: page.next_after, limit: input.limit)`); without them, page 2 lists unfiltered rows from that position on.
- **One row of the list, `page_by_key`.** Every `:page` query also gets `Queries.page_by_key(db, key: id, <the query's parameters>, filter: filter)`: the row whose last sort term (the key that tells rows apart, `id` above) is *key*, or `nil` when the page would not list it for those parameters and that filter. It is built from the page's own statement and clauses with `AND customers.id = ?` in place of the cursor's condition, so the list and "is this row still in the list" cannot disagree; an open list (`docs/views.md`, "Live updates") decides what a change means with it, and a policy can ask whether a row is visible. It takes no `order:` or `after:`.
- **Generated:** for each order and direction the condition after a cursor (`AFTER_NAME = "AND (customers.name, customers.id) > (?, ?)"`, `AFTER_NAME_DESC` with `<`; a mixed order, `total, id DESC`, becomes `AND (total > ? OR (total = ? AND id < ?))`), placed after the `WHERE` condition and its clauses, before `GROUP BY`; and `LIMIT ?` at the end.

Rules the generator checks:

| Rule | Why |
|---|---|
| The query reads, is one `SELECT` (no `UNION`), and has a `WHERE` (`WHERE true` if nothing else) | The condition after a cursor goes into it |
| No `LIMIT` or `OFFSET` | The method's `limit:` and the cursor replace them |
| Every sort term is a selected column of a table, or an alias of one; `COLLATE` is kept | The cursor takes its values from the last row, and the condition compares them in `WHERE`, where an aggregate cannot go |
| No sort column can be `NULL` | No row comes after a `NULL` in a comparison; sort by a `NOT NULL` column |
| The last term tells rows apart: a rowid or a column with a unique key of its own | Rows with equal sort values would be skipped or repeated at a page boundary |
| No `Time` sort column whose default is SQLite's `datetime()` | Its text sorts apart from the times Punch writes, so the cursor's value would be off |
| No parameter or clause named `after`, `limit`, `cursor`, `rows`, or `key` | The generated method uses these names |

The cursor holds each sort value in the form Punch stores it (`Punch::Stored.dump`), which matches the database when values were written through Punch. A value written in another form, such as a time without its fraction, compares as text and can be skipped at a page boundary; `punch db:audit` is to find such values.

**Sorting by a column that can be `NULL`.** A page cannot continue after a `NULL`, so give the order a `NOT NULL` key: a generated column that maps `NULL` to a value sorting where those rows belong, with an index for the order:

```sql
ALTER TABLE invoices ADD COLUMN sequence INTEGER NOT NULL
  GENERATED ALWAYS AS (coalesce(CAST(substr(number, 5) AS INTEGER), 0)) VIRTUAL;
CREATE INDEX invoices_by_sequence ON invoices (organization_id, sequence, id);
```

Then sort by it (`-- order number: ORDER BY invoices.sequence, invoices.id`) and select it. A `VIRTUAL` column costs no storage and needs no backfill.

For the condition to use an index, the index ends with the sort columns: `customers_by_name ON customers (organization_id, name)` serves `WHERE organization_id = ? AND (name, id) > (?, ?) ORDER BY name, id` without a sort step. `EXPLAIN QUERY PLAN` shows `USING INDEX customers_by_name (organization_id=? AND name>?)`: SQLite seeks by the name and checks the ID only among rows of an equal name. Reading an order backwards reads the same index backwards. A mixed order (`total, id DESC`) needs an index with the same directions, `(organization_id, total, id DESC)`: SQLite then reads it forwards for `asc` and backwards for `desc`, without a sort step. With a plain `(organization_id, total)` it seeks by the total and sorts the IDs of equal totals (`USE TEMP B-TREE FOR LAST TERM OF ORDER BY`).

`punch db:generate --json` lists under `pages` each order and direction with its cursor columns and condition.

## Domain types: `columns.cr`

A column is mapped once to its domain type, and every generated query uses it. Each entity maps its own tables in `columns.cr` in its directory (`app/billing/customers/columns.cr`). A composite (`Punch.composite`) maps to a group of prefixed columns or to one JSON document: `docs/composites.md`.

```crystal
Punch.table "customers", Billing::Customers,
  id: Billing::Customers::ID,
  account_id: Accounts::ID,
  email: Punch::Email,
  active: Bool,
  archived_at: Time
```

- The second argument is the module that receives the table's `Record` and `Table`. It is the file's namespace or below it: `app/billing/invoices/columns.cr` maps `invoices` to `Billing::Invoices` and `invoice_lines` to `Billing::Invoices::Lines`; a table of another namespace is refused with the file it belongs in. Each module receives one table.
- A column maps to a domain primitive (`Punch::Primitive(T)`, typed IDs included), `Time`, or `Bool`. Columns not listed keep their stored type.
- Only `STRICT` tables can be mapped, so the stored types are enforced.
- The file holds only `Punch.table` calls. The generator reads it with Crystal's parser, without compiling the app; the app requires it, and the compiler checks that each type exists and can be mapped.

| Domain type | Stored as |
|---|---|
| `Punch::Primitive(T)`, typed IDs included | its `value`, of type `T` |
| `Time` | `TEXT`, UTC with nanoseconds: `2026-10-08T14:03:00.123456789Z`; fixed width, so it sorts in time order. SQLite's `datetime()` form is read as UTC |
| `Bool` | `INTEGER`, 0 or 1 |
| `Punch::Encrypted(T)` | `BLOB`: `T`'s stored form, encrypted; see [Encrypted columns](#encrypted-columns) |
| `Punch::BlindIndex.of(:column)` | `BLOB`: a keyed hash of an encrypted column's value; see [Blind indexes](#blind-indexes) |

A primitive stored as one type cannot map to a column of another: `Billing::Customers::ID` (an `Int64`) on a `TEXT` column fails to compile in the generated file, with a message naming both.

**Rows are parsed on read.** A stored value that does not parse into its domain type raises `Punch::Database::RowError` with the table, column, row ID (when the query selected it), and the `Invalid` code. The value itself is never in the message. Tightening a domain type therefore needs an audit of existing rows first.

`Punch::Stored.dump` and `Punch::Stored.load` do the conversion; hand-written SQL can use them too.

## Records and per-table CRUD

For each mapped table, `records.gen.cr` beside its `columns.cr` holds:

```crystal
module Billing::Customers
  record Record, id : ID, account_id : Accounts::ID, name : String, email : Punch::Email, ...

  module Table
    def self.find(db : Punch::Reader | Punch::Writer, id : ID) : Record?
    def self.insert(db : Punch::Writer, *, account_id : Accounts::ID, name : String, ...) : Record | EmailTaken
    def self.update(db : Punch::Writer, record : Record) : Record | EmailTaken? # nil when the row is gone
    def self.delete(db : Punch::Writer, id : ID) : Bool
  end
end
```

- A query that returns every column of a mapped table, in order, returns its `Record` instead of a row type of its own. Narrower selects get `QueryName::Row`.
- Records are immutable. Change one with `copy_with` and write it with `update`, which sets every column.
- Behaviour goes in the file named after the record, `app/billing/customers/record.cr` for `Billing::Customers::Record`; the generated comment names it (`docs/models.md`).
- `insert` leaves out the rowid, which SQLite assigns. A column with a default takes the default when given `nil` (`coalesce(?, default)` in the SQL), so such a column cannot be set to `NULL` through `insert`.
- A composite primary key makes `find` and `delete` take keyword arguments. A table without a declared primary key gets `insert` only.
- Generated columns are read but never written.

## Encrypted columns

A column that holds personal data or a stored secret can be encrypted: its value is in no database file, backup, or replica in readable form. A column converted from plaintext gets there only after the steps at the end of "Converting a plaintext column". Declare it `BLOB` and map it as `Punch::Encrypted(T)`:

```sql
ALTER TABLE customers ADD COLUMN address BLOB;
```

```crystal
Punch.table "customers", Billing::Customers,
  id: Billing::Customers::ID,
  address: Punch::Encrypted(Punch::NonEmptyString)
```

Generated code encrypts on write and decrypts, then parses, on read. The record holds the value as `Punch::Secret(T)`, which prints as `[REDACTED]` in logs, spans, and error reports and does not serialize to JSON (`docs/core-types.md`), so writes take one and reads give one:

```crystal
Table.insert(db, name: input.name, address: input.address.try { |address| Punch::Secret.new(address) }, ...)

@address = record.address.try(&.unwrap) # in the result struct that shows it
```

- **`T`** is a domain primitive, `Time`, `Bool`, or a stored type (`String`, `Bytes`, `Int64`, `Float64`). Its stored form is the plaintext: text as UTF-8, numbers as decimal text, `Bool` as `0` or `1`.
- **One key per column,** derived from the key ring (`docs/keys.md`) for the purpose `column:<table>.<column>`. The format is the key ring's encrypted message: AES-256-GCM with a random nonce and the key's ID in a header, 33 bytes more than the plaintext. A value copied into another column does not decrypt there; within the same column it does, since the standard library has no additional authenticated data.
- **Equal values look different.** Each write encrypts with a fresh nonce, so the stored bytes say nothing about the value, and a unique key or a comparison on the column never matches. To find a row by the value or keep values unique, give the column a [blind index](#blind-indexes). The generator refuses what would compare ciphertext: a unique key or any other index on an encrypted column, a parameter or another column compared with one (`WHERE address = :address`), `LIKE`, `GLOB`, `IN`, and `BETWEEN` on one, sorting or grouping by one (`ORDER BY`, `GROUP BY`, a `-- order` clause, a page), and assigning one to another column (`SET note = address`). An expression over an encrypted column, such as `coalesce(address, ...)`, is ciphertext, typed `Bytes`; nothing checks what such an expression is compared with.
- **Rules on the value live in `T`** and the input: a `CHECK` constraint sees only ciphertext, and the generator refuses one that reads the column.
- **A value that does not decrypt** raises `Punch::Database::RowError` with the reason `not_decrypting`: a value moved from another column, damaged, or encrypted under a key the ring no longer has. Like every row error, the message names table, column, and row, never the value.
- **Writes use the signing key;** reads accept every key of the ring. `Table.update` encrypts every column again, so an updated row moves to the current key, and [`punch db:encrypt`](#converting-and-re-encrypting-dbencrypt) moves every other row.
- **Names:** the table and column names of an encrypted column are lowercase letters, digits, and `_`, since its key is derived from them; renaming either changes the key, so existing values stop decrypting.
- **Specs:** a key ring must be loaded (`Punch::Spec.credentials`). `raw.should be_encrypted_for("customers", "address")` checks that a value read straight from the database is ciphertext this column's key opens.
- **The database shell** (`punch db:shell`) shows the ciphertext.

## Blind indexes

A blind index finds an encrypted value without decrypting anything: a second `BLOB` column holds a keyed hash of the value. An index on it finds equal values, and a unique index keeps them unique. Map it with `Punch::BlindIndex.of` and the encrypted column it hashes:

```sql
ALTER TABLE customers ADD COLUMN tax_id BLOB;
ALTER TABLE customers ADD COLUMN tax_id_index BLOB;
CREATE UNIQUE INDEX customers_by_tax_id ON customers (organization_id, tax_id_index);
```

```crystal
Punch.table "customers", Billing::Customers,
  tax_id: Punch::Encrypted(Billing::Customers::TaxID),
  tax_id_index: Punch::BlindIndex.of(:tax_id)
```

- **The generated `Table` writes it.** `insert` and `update` hash the encrypted column's value into the index, so they take no argument for it, and the record has no field for it: a whole-row query reads past it.
- **Queries compare it with a parameter, as `tax_id_index = :tax_id`**, column first. The parameter takes the encrypted column's `T` (`Billing::Customers::TaxID`), not a `Secret`, and the generated method binds its hashes. Nothing else reaches a blind index: the generator refuses it compared with anything but a parameter (another column, a literal), the parameter reversed, in `IN` or `BETWEEN`, compared with `<` or `>`, sorted or grouped by, and a parameter that is also used elsewhere in the query. A declared clause works the same way: `-- when tax_id: AND tax_id_index = :tax_id` gives the filter a `tax_id : TaxID?` field.
- **A hand-written write** of the encrypted column writes the index too, from a parameter of its own that takes the plain value: `UPDATE customers SET tax_id = :tax_id, tax_id_index = :tax_id_index WHERE id = :id`, called with `tax_id: Punch::Secret.new(value), tax_id_index: value`. The audit reports a write that forgets it.
- **A unique index on it gives a violation named after the encrypted column:** `UNIQUE (organization_id, tax_id_index)` is `TaxIdTaken`, at the field `tax_id`, as for any unique column ([Violations](#violations)).
- **Equal means equal stored forms.** The hash is over `T`'s stored form, the encrypted column's plaintext, so a type that normalizes (`TaxID.parse` drops spaces and capitalizes) finds a value however it was written. A hash finds the whole value only, never a part, a prefix, or a range.
- **Key and format:** HMAC-SHA256 under a key the key ring derives for the purpose `blind_index:<table>.<column>`, with the key's ID in front: `version (1) | key id (4) | HMAC (32)`, 37 bytes. The names follow the encrypted column's rules (lowercase letters, digits, `_`; renaming changes the key). `Punch::Stored.blind_index(value, table, column)` gives the stored value, for hand-written SQL and specs.
- **Rotation works like ciphertext's** (`docs/keys.md`). A write hashes under the signing key; a lookup hashes the parameter under every key of the ring and matches any of them, so rows written before a rotation are still found. The generated SQL says so: `tax_id_index = :tax_id` runs as `tax_id_index IN carray(?)`, bound to the hashes; the index is used as before. `tax_id_index IN carray(:tax_ids)` finds the rows of several values the same way. `Table.update` hashes again under the current key.
- **During a rotation, uniqueness holds per key.** The same value hashed under two keys is two index values, so a unique index catches a second customer with the same tax number only once both are hashed under the same key. `punch db:encrypt` hashes every row again under the signing key and reports the rows whose new hash another row already has (`taken`); merge or change those, and run it again.
- **It is audited:** `db:audit` checks each hash against the decrypted value of its row, reports `index_stale` (a hash of something else, or a hash without a value) and `index_missing` (a value without a hash), and lists the hashes per key like an encrypted column's values.
- **What it leaks:** equal values have equal hashes under one key, so anyone with the database file sees which rows share a value, and can test guesses of a value only with the key. Do not index a value with few possible values (a `Bool`, a country), whose hashes are then as good as the values.

## Converting a plaintext column

A column that already holds personal data in plaintext becomes an encrypted one over three releases, so that no process meets a row it cannot read while two of them run during a deploy (`docs/deployment.md`). A `STRICT` `TEXT` column cannot hold ciphertext, so the ciphertext goes into a new `BLOB` column beside it, and the plaintext column is dropped at the end. The reference app converts `customers.email` this way (`reference/db/migrations/*_encrypt_customer_emails.sql` and the two migrations after it).

**Release 1: read either, write both.** A migration adds the encrypted column (and a blind index with its unique index, if the value is looked up or unique), and `columns.cr` maps it with `from`, naming the plaintext column, which it no longer maps itself:

```sql
ALTER TABLE customers ADD COLUMN email_encrypted BLOB;
ALTER TABLE customers ADD COLUMN email_index BLOB;
CREATE UNIQUE INDEX customers_by_email_index ON customers (organization_id, email_index);
```

```crystal
Punch.table "customers", Billing::Customers,
  email_encrypted: Punch::Encrypted(Punch::Email).from(:email),
  email_index: Punch::BlindIndex.of(:email_encrypted)
```

- The record has one field, `email_encrypted : Punch::Secret(Punch::Email)`: the ciphertext when the row has it, else the plaintext, parsed. It is not nilable when the plaintext column is `NOT NULL`. A narrower query that selects `email_encrypted` without `email` gets only the ciphertext (nilable).
- `Table.insert` and `update` take `email_encrypted` and write it to both columns, and the blind index, so the release before still reads every row.
- Rows written before have no ciphertext: `punch db:encrypt` converts them (below), and the nightly job does it too. `db:audit` counts what is left: `customers.email_encrypted: converting from email, 12 only in plaintext, 340 plaintext copies left`.
- Lookups and uniqueness move to the blind index once no row is only in plaintext; until then, queries on `email` still work.

**Release 2: clear the plaintext.** When `db:audit` shows nothing only in plaintext, map it with `clear: true`:

```crystal
  email_encrypted: Punch::Encrypted(Punch::Email).from(:email, clear: true),
```

- Generated code now leaves `email` out entirely: the record reads only the ciphertext, and `Table` writes NULL into it by leaving it out. The generator refuses any query that names `email` or selects it with `*`, so that this release keeps working once the next one drops the column: list the columns instead.
- So `email` must be nullable first, and a constraint on it (such as a unique key) goes: both need a migration that rebuilds the table (`docs/migrations.md`), in this release. The same migration can make `email_encrypted` and `email_index` `NOT NULL`, since every row has them by now; it fails at boot otherwise, and the deploy stops.
- `punch db:encrypt` (and the nightly job) sets the remaining plaintext to NULL; `db:audit` counts the copies left. It first checks that the ciphertext holds the plaintext: a row where it does not decrypt or holds another value (the release before wrote the plaintext alone during the deploy) is reported, `not_decrypting` or `plaintext_differs`, and keeps both until you decide which is right.

**Release 3: drop it.** A migration drops `email` (`ALTER TABLE customers DROP COLUMN email`, a rebuild to acknowledge), and `columns.cr` maps `email_encrypted: Punch::Encrypted(Punch::Email)` without `from`.

The record's field is named after the encrypted column, `email_encrypted`; its key is derived from that name, so it stays. A result struct or input can still call it `email`.

**After release 3: remove what is left.** The writer zeroes what it deletes (`secure_delete`, `docs/persistence.md`), but a database written before Punch set it, or by another tool, may still hold the plaintext in free pages. Rebuild the file and empty the WAL once, at a quiet time, since `VACUUM` rewrites the whole file and blocks writes while it runs:

```text
$ punch db:shell storage/primary.db "VACUUM; PRAGMA wal_checkpoint(TRUNCATE);"
```

Backups are not rewritten: Litestream's generations from before keep the plaintext until its retention removes them, and a restore from one of them brings the plaintext back.

## Converting and re-encrypting: `db:encrypt`

`punch db:encrypt [PATH] [--env NAME]` brings every encrypted column to the key ring's signing key:

```text
$ punch db:encrypt
storage/primary.db: 1220 rows read, 352 written, under key 2.
  customers.email_encrypted: 12 converted, 340 encrypted again
  customers.email_index: 352 hashed again
  customers.address: 40 encrypted again
```

- **Converts** a column mapped with `from`: a row with plaintext and no ciphertext gets the ciphertext of the parsed value. Plaintext that does not parse stays, reported with its reason and row.
- **Re-encrypts** a value under an older key, and **hashes again** a blind index under an older key or not matching its value, so that a key can retire once `db:audit` counts nothing under it (`docs/keys.md`).
- **Clears** the plaintext of a column mapped with `clear: true` once the ciphertext is there.
- **Leaves and reports** what it cannot change: a value that does not decrypt (`not_decrypting`), and a row whose new blind index another row has (`taken`, two values that were equal under different keys). It then fails (`values_left`); fix the rows and run it again.
- **Safe beside the running app:** batches of 500 rows by rowid, each one write transaction, writing only rows that change. Run it as a command of the app's binary, with the credentials of the database's environment.
- **Every night**, `Punch::Database::Encryption::Run`, a recurring Punch job, does the same at 04:00 UTC with priority -100. It runs in steps (`docs/jobs.md`, "Long jobs: steps"): each batch saves where it got to in the same transaction, so a deploy or a crash resumes after the last batch instead of starting over. Its job run carries `punch.encryption.rows`, `.written`, and `.findings` (the columns with values left as they are, at most 20 lines), counted since the run began. After a key rotation (`docs/keys.md`) or a release 1 or 2, run the command rather than wait.
- Punch's own encrypted values, the second factor's secrets (`docs/auth.md`), are moved too.

`punch db:generate` writes a `reencrypt` method into the `Table` of every table with an encrypted column and registers it with `Punch::Database::Encryption.table`, like the audit.

## Violations

A unique constraint is the one rule only the database can decide, so a write that can break one returns it as a value. For each unique index, `UNIQUE` constraint, and primary key of a mapped table, `records.gen.cr` holds a struct in the table's module:

```crystal
module Billing::Customers
  # Another `customers` row has this email. Returned by the writes that can violate it.
  struct EmailTaken
    include Punch::Database::Violation

    CONSTRAINT = "customers.email"
    FIELD      = "email"
    MESSAGE    = "UNIQUE constraint failed: customers.email"
  end
end
```

- **Named after the columns that are not foreign keys:** `UNIQUE (email)` is `EmailTaken`, `UNIQUE (invoice_id, position)` is `PositionTaken`. A key of foreign keys only uses all of them (`TeamIdMemberIdTaken`); an index on expressions uses the columns it reads (`lower(email)` is `EmailTaken` too, unless that name is taken, then every key column, then the index name). A rowid's `IdTaken` exists only when a query sets the ID. A key that contains a smaller key without a `WHERE` has no type, since it cannot be violated: `UNIQUE (owner_id, id)`, which a composite foreign key needs, is unique through `id` alone.
- **Its field** is that one column, `nil` (the input as a whole) when there is more than one.
- **Which writes return which:** `Table.insert` and `Table.update` return every constraint they can break, and so does a named `INSERT` or `UPDATE` of a mapped table: an insert the constraints whose key columns all get a value (a column left out is `NULL` unless it has a default, and `NULL`s never conflict), an update those that read a column it sets (a partial index's `WHERE` included). `ON CONFLICT (columns)` removes that constraint, `ON CONFLICT` without a target all of them; `DO UPDATE SET` adds those of its columns. `INSERT OR IGNORE`, `OR REPLACE`, and `REPLACE` never fail; `OR FAIL` and `OR ROLLBACK` leave more than one statement's effect behind, so they raise. The answer errs towards an extra `in` branch, never towards a missing one.
- **Result types:** `:one` gives `Row | EmailTaken?`, `:many` `Array(Row) | EmailTaken`, `:exec` `EmailTaken?` (`nil` when it worked), `:execrows` `Int64 | EmailTaken`.
- **Only the statement is undone;** the transaction goes on. SQLite names the failing constraint in its message, which the generated method compares with `MESSAGE`.
- **Everything else still raises** `Punch::Database::ConstraintError`: foreign keys (SQLite does not say which one failed; check that the row exists in the Command first), `CHECK`, `NOT NULL`, constraints of unmapped tables, and writes made through triggers on other tables. `Punch/ConstraintRescue` reports rescuing it in app code.

In a Command, handle each with `case … in`, and return the violation itself: it answers 422 with `taken` at its field, like a rejected input, as Problem Details and as a field error on the form (`docs/views.md`), and `openapi.json` documents it as the input's 422.

```crystal
def call(input : Input, db : Punch::Writer, _actor : Invoicing::Actor) : Created | EmailTaken
  case created = Table.insert(db, name: input.name, email: input.email, created_at: Time.utc)
  in Record     then Created.new(Customer.new(created))
  in EmailTaken then created
  end
end
```

No lookup before the insert is needed: the Command holds the write lock, and the index decides. A Command that returns a violation whose field its input does not have does not compile; return `violation.rejection("contact", "email")` (a `Punch::Rejection`) with the field's path instead. A Command may return a `Punch::Rejection` of its own for any rule it checks against other rows.

**A Command's failure writes nothing.** When a Command returns a rejection, a violation, or any result with a status from 400 on, its transaction rolls back, so an event recorded before the failing insert is gone as well, and a sign-in in the same Command is not applied.

Where a write cannot violate by construction, such as positions numbered by the code, `Punch.cannot_violate(write)` returns the result without its violations and raises if one happens anyway, because then the construction was wrong.

### Rules raised by triggers

A rule over several rows that a trigger enforces becomes a value the same way. The trigger raises a code with `RAISE(ABORT, 'punch:<code>')`, and the `columns.cr` that maps its table declares the code, its type, and its status:

```sql
-- db/migrations/…
CREATE TRIGGER invoices_locked BEFORE UPDATE ON invoices
WHEN OLD.sent_at IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'punch:invoice_locked'); END;
```

```crystal
# app/billing/invoices/columns.cr
Punch.violation "invoice_locked", Billing::Invoices::Locked, status: 409
```

- **`status: 409`** answers as a problem with the code (`invoice_locked`) for the request as a whole; **`status: 422`** answers like a rejected input, with the code at `field:` when one is given (`Punch.violation "handle_empty", …, status: 422, field: "handle"`), else at the input as a whole. Either is a failure, so the Command rolls back.
- **The type is generated** in `records.gen.cr`, in the table's module, with the code as `PROBLEM_CODE`; `Punch.violation` does not compile until `punch db:generate` has written it.
- **Which writes return it:** those that fire a trigger raising the code: inserts for `INSERT` triggers, updates for `UPDATE` triggers (with `UPDATE OF` columns, only updates that set one of them), and deletes for `DELETE` triggers, `Table.delete` included (`Bool | LastMember`).
- **Checked by `punch db:generate`:** a declared code that no trigger raises, a code raised by triggers on two tables, a type outside the table's module, and a trigger on a mapped table that raises an undeclared `punch:` code, or raises one with `ROLLBACK`, `FAIL`, or `IGNORE`, are errors. The message stays a string literal so the generator can find it. Triggers on unmapped tables raise `Punch::Database::ConstraintError`, as their unique violations do.

## Auditing stored values: `db:audit`

Rows are parsed into domain types when read, so tightening a type (a stricter email, a shorter name) turns old rows into read failures. `punch db:audit` finds them first: it parses every mapped column of every row against the types the binary has.

```
$ bin/invoicing db:audit
storage/primary.db: 1204 rows in 6 tables, values that do not parse.
  customers.email: 2 values do not parse as Punch::Email (2 invalid_email); rows 17, 210
  customers.created_at: 1 value is not in Time's stored form; rows 3
  customers.address: encrypted, 310 under key 2, 4 under key 1
  customers.tax_id_index: blind index, 120 under key 2
```

- **Two findings per column.** A value that does not **parse** would raise `Database::RowError` when a query reads it; it fails the command (exit 1, `values_do_not_parse`). A value that parses but is **not in its stored form** (a time written by SQLite's `datetime()`, text that normalization would change) reads fine but compares and sorts unlike what Punch writes, which matters to page cursors; it is reported without failing.
- **No values in the report,** only table, column, type, the reason code from the type's parser, a count, and the first ten row IDs (rowids). `--json` gives `{"database", "audit": {"started_at", "finished_at", "clean", "rows": {table: count}, "findings": [{"table", "column", "type", "invalid": {reason: count}, "invalid_rows", "noncanonical", "noncanonical_rows"}], "encrypted": [{"table", "column", …, "keys": {key ID: count}}]}}`.
- **Encrypted columns** are decrypted, then parsed; a value that does not decrypt is `not_decrypting`. A blind index is checked against its row's decrypted value (`index_stale`, `index_missing`), and a column being converted counts what is left in plaintext ([Converting a plaintext column](#converting-a-plaintext-column)). Each of them also gets a line with its values per key, read from the header: a key that still has values is not safe to retire (`docs/keys.md`). Decrypting needs the key ring of the database's environment: the command loads the credentials of `--env NAME` (else `PUNCH_ENV`, else `development`) and fails with their problems when it needs the ring and cannot load it.
- **It is a command of the app's binary** (`bin/<app> db:audit [PATH]`), which has the types; the `punch` tool refuses with `no_audits`. Without PATH it reads the primary database in `PUNCH_STORAGE`; with one, any copy, such as a replica restored with Litestream, so a type change can be checked against production data without touching production.
- **Every night**, `Punch::Database::Audit::Run`, one of Punch's recurring jobs, audits the primary database at 03:00 UTC with priority -100, yielding after every batch. Its job run carries `punch.audit.rows`, `.tables`, `.invalid`, `.noncanonical`, and `.findings` (the report's lines) in the ops console, and each column with values that do not parse is an error there, `Punch::Database::Audit::Unparseable`, grouped per column. It never fails the job: the data is the problem, not the run.
- **In batches of 500 rows** by rowid, each in its own read transaction, with a span `punch.audit.table` per table. A long audit holds no transaction open and blocks no writer.

`punch db:generate` writes an `audit` method into each mapped table's `Table` module and registers it with `Punch::Database::Audit.table` at the end of its `records.gen.cr`. Columns without a domain type are not parsed (`STRICT` already enforces their storage type), and `WITHOUT ROWID` tables are not audited.

**Tightening a type,** a two-step change: change the type, build, run `db:audit` against a restored copy of production; fix the rows it names (a migration or a Command); then ship.

## Commands

| Command | Does |
|---|---|
| `punch db:generate [FILES…]` | Generates from `db/schema.sql`, every `columns.cr`, and every `.sql` file under `app/` and `src/` (or the files given). Writes only files that changed |
| `punch db:generate --check` | Writes nothing; fails with `stale_generated_files` when a committed file differs. For CI and `punch check` |
| `bin/<app> db:audit [PATH]` | Parses every mapped column of every row; fails when a value does not parse ("Auditing stored values") |
| `punch db:explain [--check] [--all]` | The plan of every statement of every named query; full scans and sorts the query does not accept fail `--check` ("Query plans") |
| `--json` | Every file with its state; every query with its kind, location, result type, included modules, violations, and each column and parameter with its type and where the type came from; every mapped table with its module, behaviour file, and violation types (constraint, index, field) |

Never edit a generated file; change the source and run the generator. Its output goes through Crystal's formatter, so it passes `crystal tool format --check` and Ameba.

`punch db:generate` is part of the standalone `punch` binary only. Application binaries do not compile the generator.

## Tracing

Every generated method names its statement's span after itself, `Billing::Invoices::Queries.for_customer` or `Billing::Invoices::Table.find`, so a trace or wide event leads straight to the `.sql` file and the query (`docs/tracing.md`).

## Testing

Start a database from the schema and seed it with the generated inserts:

```crystal
Punch::Spec.database(schema: "db/schema.sql") do |db|
  db.write do |writer|
    customer = Punch.cannot_violate(Billing::Customers::Table.insert(writer, account_id: account.id, name: "Ada", email: email))
    Billing::Invoices::Queries.for_customer(writer, customer_id: customer.id, limit: 10).should be_empty
  end
end
```

## SQL text is never built from values

Every value reaches SQLite as a bound parameter, and the text of a statement comes from the source alone. The Ameba rule `Punch/SQLText` (run by `punch check`) checks the SQL argument (the first, or the one named `sql:`) of `exec`, `query_all`, `query_one?`, `query_each`, and the driver's methods, in the app (`db/seeds.cr` included) and in Punch, also inside macros. It accepts:

| Accepted | Example |
|---|---|
| A string literal, or one that interpolates only constants | `"SELECT #{COLUMNS} FROM punch_sessions WHERE id = ?"` |
| A constant, or an element of a tuple constant the same file defines from accepted parts | `Queries::Find::SQL`, `TABLES.each { \|sql\| db.exec(sql) }` with `TABLES = {"CREATE …", "CREATE …"}` |
| `+`, `? :`, and parentheses of accepted parts | `desc ? ORDER_DESC : ORDER` |
| A local whose every assignment is accepted, including a `String.build` whose `io` receives only constants and literals | the generated method of a query with clauses |

Anything else is reported: `"… '#{name}'"`, `"… " + table`, `"… %s" % order`, a `String.build` that appends a value, an instance variable, an element of an array or a hash (anything can be added to one), or a method's parameter, unless that method is itself one of the checked ones and takes the SQL first (the database layer passing SQL inward; its callers are then checked, on a module too: `Helper.exec(db, sql)`). In a macro, each `{{ … }}` counts as a value. A choice of column or sort is a declared `-- order`, never a name from the request (`Queries::Page::Order` parses `?order=name`).

Where SQL text comes from a file at run time (a migration, `db/schema.sql`), the line says so with `# ameba:disable Punch/SQLText` and a comment why. Punch has six such lines: the three that run migration scripts (applying them, loading `db/schema.sql`, and `db:cost`'s rehearsal), the driver's `shape` and `query_plan` (the generator's view of a query file's statement, never run), and the one statement SQLite cannot bind, `PRAGMA name = value`, whose names and values `Database::Config` checks against fixed patterns. Specs (`*_spec.cr` under `spec/`) are not checked.

## Query plans: `punch db:explain`

`punch db:explain` asks SQLite how it would run every named query (`EXPLAIN QUERY PLAN`) and reports two kinds of step:

| Kind | Plan step | Means |
|---|---|---|
| `scan` | `SCAN customers`, `SCAN customers USING INDEX …` | Reads every row of a table, in table or index order. A scan of a subquery, CTE, or virtual table is not counted |
| `sort` | `USE TEMP B-TREE FOR ORDER BY` (or `GROUP BY`, `DISTINCT`) | Sorts every row it read before returning the first |

A query with declared clauses has many statements, and each is explained: what the generator prepares (every `when` with each order, each `when` alone, pages after a cursor), and what a request most often runs: no filter and each `when` alone, with each order, and for a `:page` query after a cursor. Orders read backwards are left out, because an index serves both directions. A finding names the statement, such as `(only when status, order name)`.

Where a scan or sort is fine, the query's header says why:

```sql
-- name: Statement :many
-- One customer's sent invoices per currency.
-- sort: one customer's sent invoices, grouped by currency
SELECT ...
```

`-- scan: <reason>` and `-- sort: <reason>` each accept their kind for every statement of the query; the reason is required. A line whose kind no statement has is an error, so it does not outlive the reason.

`punch db:explain --check` fails on any other finding; `punch check` runs it as the step `explain`, after `queries`. `--all` prints every statement's plan; `--json` gives `{"queries": [{"name", "location", "accepted", "problems", "statements": [{"label", "sql", "plan": [{"depth", "detail"}], "findings": [{"kind", "text"}]}]}]}`.

```
$ punch db:explain
15 queries, 34 statements: 1 with a full scan or sort (1 accepted)
app/billing/customers/queries.sql:21:1 Statement
  sort  sorts every row it reads for GROUP BY; accepted: one customer's sent invoices, grouped by currency
```

The plans come from `db/schema.sql` without data or statistics, as a new database has them. After `PRAGMA optimize` has gathered statistics in production, SQLite may choose other plans; a check against a copy of production data is not part of `punch check`.

## Not yet

- Annotating an expression column with a domain type.
- Array parameters in queries with declared clauses or pages.
