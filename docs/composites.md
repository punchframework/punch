# Composites: groups of columns and JSON documents

Learn it in: [Composites: Value Types on a Row](guides/composites.md).

A composite is a value type made of named fields, declared once like a table and stored on a row, either as a group of prefixed columns or as one JSON document. It is parsed on read like every column: a stored value that does not parse is a `Punch::Database::RowError` naming the table, column, row, and the path in the document, never the value. A map's entries are named by position (`$.prices{2}`), since their keys are data.

| Need | Use |
|---|---|
| A value object on a row, queried, indexed, or referencing other rows | a group of columns |
| A list queried per element, referenced from elsewhere, edited concurrently, or unbounded | a child table |
| A snapshot frozen at a moment (what an invoice was billed to) | a JSON document |
| Several fields encrypted together as one value | a JSON document, `Punch::Encrypted(T)` |
| A small bounded list or map owned by its row and never queried per element | a JSON document |
| One of several shapes (a card or a transfer) | a polymorphic composite, as a JSON document |
| Data whose shape the app does not own (webhook bodies) | not a composite: keep the text |

## Declaring a composite

```crystal
# app/billing/composites.cr: composites several entities of the slice use
Punch.composite Billing::Address,
  street: Punch::NonEmptyString,
  postal_code: Punch::NonEmptyString,
  city: Punch::NonEmptyString,
  country: {type: Punch::NonEmptyString, default: "DE"},
  geo: Billing::Geo?

# app/billing/invoices/columns.cr: a composite only this entity uses
Punch.composite Billing::Invoices::BilledTo,
  customer_id: Billing::Customers::ID,
  name: Punch::NonEmptyString,
  company_name: Punch::NonEmptyString?,
  address: Punch::NonEmptyString?,
  tax_id: Billing::Customers::TaxID?
```

- **Where:** composites several entities share go into the slice's `composites.cr`, generated into `composites.gen.cr` beside it; a composite one entity uses goes into that entity's `columns.cr` and its `records.gen.cr`. `punch db:generate` reads both with Crystal's parser, without compiling the app. A file declares only composites of its own namespace.
- **The struct** has a getter per field. Behaviour goes in the file named after it (`app/billing/address.cr` for `Billing::Address`), which reopens the struct; `punch requires:generate` requires it after the generated file.
- **Always parsed.** There is no public `new`. `Billing::Address.build(street: …, …)` returns `Billing::Address | Punch::Invalid`, and so does `copy_with`: both check the bounds below and, when the composite defines it, its own rule across fields:

  ```crystal
  struct Billing::Geo
    def self.check(value : self) : Punch::Invalid?
      Punch::Invalid.new("out_of_range") unless -90 <= value.lat <= 90
    end
  end
  ```

  Reads run the same `check`, so no invalid composite exists in the program. Specs unwrap with `.as(Billing::Address)`, as for primitives.
- **Field types:** a domain primitive (typed IDs and `Punch::Money` included), `Time`, `Bool`, `String`, `Int64`, `Float64`, another composite, any of them nilable with `?`; in documents also bounded arrays and maps (below); in groups also `Punch::Encrypted(T)`. A composite that contains itself, directly or through others, is refused.
- **Options** are literals, fields are types, so a field may be called `version`: `version: 2, from: {1 => V1}` (versions), `max_bytes: 32768` (a document's size), `max_depth: 40` (its nesting), `discriminator:` and `one_of:` (polymorphic). On a polymorphic composite, `max_bytes:` and `max_depth:` apply to each member.
- **Defaults:** `{type: Punch::NonEmptyString, default: "DE"}`, a string, number, or `true`/`false` literal, on a field that is not nilable. The generated file parses each default at program start, so every spec run, `punch check`, and boot fail on one that does not parse, naming the declaration's line. In a document a default fills a missing key, so adding a field with a default needs no new version. In a group the column must be `NOT NULL DEFAULT` the same literal (the generator compares).
- **Typed IDs** are allowed. Inside a document nothing keeps them consistent (no foreign key): they are references as they were ("was customer 42"). In a group they are columns and may have a foreign key.
- **Punch ships four,** `Punch::Upload::File`, `PrivateFile`, `ImageFile`, and `PrivateImageFile` (`docs/uploads.md`): an app maps them as groups without declaring them.
- **Inputs stay separate.** A composite is a stored type, not a `Punch::Input`: an operation builds one from its input with `build`, or changes a loaded one with `copy_with`.
- **In answers** a composite shows its declared fields under their names, `nil` ones left out (no version, no keys it does not know), with its JSON Schema in `openapi.json`. Renaming a field changes the API, which `punch openapi:diff` reports. One with an encrypted field does not compile in an answer: pick the fields to show.
- **Equality** compares declared fields only.
- **From JSON** a composite is read only as stored JSON (`Punch::Stored.from_json`: job payloads, cached values), where typed IDs are rowids; `Address.from_json(text)` elsewhere is refused (`not_stored_json`).

## Stored as a group of columns

```crystal
Punch.table "sites", Billing::Sites,
  address: {type: Billing::Address, columns: "address_"},
  billing: {type: Billing::Address?, columns: "billing_"}
```

Each field is a column named by the prefix and the field, a nested composite joining its own (`address_geo_lat`). The columns are plain columns: foreign keys, indexes, `CHECK`s, and migrations work as for any. The record holds one field, `address : Billing::Address`, and `Table.insert` and `update` take the composite.

- A field that is not nilable needs a `NOT NULL` column, a nilable one a column that can be `NULL`.
- **A nilable group** (or a nilable composite inside one) is absent when all its columns are `NULL`. A `CHECK` must keep its required columns all `NULL` or all set; the generator refuses the mapping without one and prints it: `ALTER TABLE sites ADD CHECK (((billing_street IS NULL) + (billing_city IS NULL)) IN (0, 2) AND …)`. A row that holds part of one is a `RowError` with the reason `partial_group`. A nilable group with an encrypted field cannot be mapped yet, since that `CHECK` would read the encrypted column.
- **In queries** each column has its field's type (`WHERE address_city = :city` takes a `Punch::NonEmptyString`). A query that selects every column of a group gets it as one field; some of them stay separate fields.
- **Encryption per field:** a field `Punch::Encrypted(T)` is an encrypted `BLOB` column with its own key, and may have a blind index (`address_tax_id_index: Punch::BlindIndex.of(:address_tax_id)`), while the other columns stay plain.
- **Changes** are migrations, as for any column. No versions.
- No lists, maps, or polymorphic composites in a group: an owned list is a child table or a document.

## Stored as a JSON document

```sql
-- encrypted as a whole: a BLOB, no CHECK (it is ciphertext)
ALTER TABLE invoices ADD COLUMN billed_to BLOB;

-- plain: TEXT, kept JSON by a CHECK
ALTER TABLE orders ADD COLUMN shipping TEXT
  CHECK (shipping IS NULL OR (json_valid(shipping) AND json_type(shipping) = 'object'));
```

```crystal
Punch.table "invoices", Billing::Invoices,
  billed_to: Punch::Encrypted(Billing::Invoices::BilledTo)
```

- **Column:** `TEXT` with that `CHECK`, which the generator requires and prints when it is missing, or a `BLOB` for `Punch::Encrypted(Composite)`, an encrypted column like any other (`docs/queries.md`, "Encrypted columns"). A plain document cannot hold an encrypted field; encrypt the whole document.
- **Shape:** an object with the declared fields under their names; a `nil` field is left out, never `null`; `Time` in Punch's fixed-width UTC form; `Punch::Money` an integer; typed IDs their rowid, also with a public form.
- **Bounded:** an array or map declares its bound, `{type: Array(Billing::Line), max: 200}` and `{type: Hash(Punch::Currency, Punch::Money), max: 10}` (a map's key is `String` or a domain primitive stored as `String`), shown as `maxItems` and `maxProperties` and checked by `build` and on read (`too_many`). A document is at most 16 KiB of JSON unless it says `max_bytes:` (`too_large`), and nests objects and arrays at most 32 deep, the document itself counting as 1, unless it says `max_depth:` (at most 64; `too_deep`). The parser stops at the bound, so a deep document costs no deep recursion, and the bound stays below the depth Crystal's JSON writer refuses, so a document that reads, with keys it carried, can always be written back. The generator refuses a `max_depth:` below what the declaration itself nests. A document with a key twice is refused (`duplicate_key`): SQLite's paths and indexes read the first, a parser that builds a hash the last. A `Float64` that is not finite makes `build` return `not_finite`. Elements are positional: changing one writes the array again; a list that needs identity is a child table.
- **Keys a newer release wrote are kept.** A document read from the database carries the keys its type does not declare and writes them back: `doc.copy_with(city: …)` keeps them, `build` starts without. So an older release, after a rollback, does not erase a newer one's fields. Keys of an array element are kept while the element is carried over.
- **Written whole:** through `Table.insert` and `update`, or a query parameter assigned to the column (`SET payment = :payment` takes the composite).

## Polymorphic composites

```crystal
Punch.composite Billing::Payments::Method,
  discriminator: "kind",
  one_of: {card: Billing::Payments::Card, transfer: Billing::Payments::Transfer}

Punch.composite Billing::Payments::Card, last4: Punch::NonEmptyString, brand: String
Punch.composite Billing::Payments::Transfer, iban: Punch::NonEmptyString, reference: String?
```

`Billing::Payments::Method` is the union of its members, so the compiler checks a `case … in` over it:

```crystal
case method = payment.method
in Billing::Payments::Card     then method.last4
in Billing::Payments::Transfer then method.iban
end
```

A stored member writes its tag under the key, `{"kind":"card","last4":"4242",…}`, and reading picks the member by it (`unknown_member` for another tag). A member is a composite of its own, in one polymorphic composite only, and has no field named like the key; answers show the tag, and the schema is a `oneOf` with OpenAPI's `discriminator`. Polymorphic composites are stored only as documents.

## Paths in queries

A path into a plain document is typed from the composite, in `SELECT`, `WHERE`, and parameters compared with it:

```sql
-- name: OrdersIn :many
SELECT id, shipping ->> '$.address.city' AS city, json_extract(shipping, '$.lines[0].quantity') AS first_quantity
FROM orders
WHERE account_id = :account_id AND shipping ->> '$.address.country' = :country;
```

`city` is a `Punch::NonEmptyString`, `first_quantity` a `Float64?` (an element may be missing), and `:country` takes a `Punch::NonEmptyString`. A path reads `.field`, `."key"`, and `[n]`; `->> 'field'` is short for `$.field`. A path is nilable where the document may lack it: a nilable field, a field with a default (older documents), an array element, a map entry, a field only some members of a polymorphic composite have. A path to a nested composite gives that composite; one to an array or map gives its JSON text. The generator refuses a path the composite does not declare and any path into an encrypted document (it would read ciphertext). Paths only read: a document is written whole.

A path read often gets a generated column, typed from the path, and an index on it:

```sql
ALTER TABLE orders ADD COLUMN ship_city TEXT GENERATED ALWAYS AS (shipping ->> '$.address.city') VIRTUAL;
CREATE INDEX orders_ship_city ON orders (account_id, ship_city);
```

## Versions

Documents outlive releases, so composites stored as documents follow the rules of job payloads (`docs/jobs.md`, "Payloads across deploys"). Their shapes are in the `documents` section of `payloads.lock.json` (`punch jobs:lock`, checked by `punch check`): adding a nilable field or one with a default is compatible; removing a required field, retyping one, or renaming one needs a new version, with the old shape kept as a frozen type:

```crystal
Punch.composite Billing::Invoices::BilledTo,
  version: 2, from: {1 => Billing::Invoices::BilledTo::V1},
  name: Punch::NonEmptyString,
  # ...

struct Billing::Invoices::BilledTo
  # Version 1: the name as plain text.
  struct V1
    include Punch::Payloads::Frozen

    getter name : String

    def upgrade : BilledTo | Punch::Invalid
      # ...
    end
  end
end
```

- A document above version 1 stores it as `"$v": 2` (absent means 1). Reads upgrade older ones through the frozen types; the next save writes the current version. An `upgrade` that returns `Punch::Invalid` makes the row unreadable with that code.
- A document of a newer version than the binary reads (written by a newer release, then rolled back) is a `RowError` with the reason `newer_version`. Start writing a new version only once the release before it is settled.
- **`punch db:upgrade`** and the nightly `Punch::Database::Upgrade::Run` (04:30 UTC, in steps, resumable) rewrite documents of older versions, and documents not in their stored form, a batch per transaction; a newer version or one that does not parse stays as it is and is reported by row. **`punch db:audit`** counts each document's objects per composite and version (`orders.billed_to: 3 Billing::Invoices::BilledTo version 1, …`). Delete a frozen type once no row of its version is left; `punch check` notes the deletion.

## Rules

- Declare composites with `Punch.composite` in `composites.cr` or the entity's `columns.cr`; never write the struct by hand, and put behaviour in the file named after it.
- Make one only with `build` or `copy_with`, and handle `Punch::Invalid`; never rescue a `RowError` to read past a bad document.
- Bound every array and map. Prefer a child table for a list that is queried, referenced, edited concurrently, or unbounded.
- Encrypt personal data: a whole document as `Punch::Encrypted(T)`, a group's field as `Punch::Encrypted(T)`.
- Change a document's shape compatibly, or raise its version with a frozen type; never edit a frozen type.
- Give a nilable group the `CHECK` the generator prints, and a plain document its `json_valid` `CHECK`.
