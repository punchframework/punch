# Composites: Value Types on a Row

Applies to Punch 0.1.

Some values are made of several fields that only mean something together: a postal address, a price per currency, a card or a bank transfer. In Punch, such a value is a composite. You declare it once, like a table, and store it on a row, either as a group of columns or as one JSON document. Reads parse it like every other column, so a composite in the program is always valid, and queries see its fields with their domain types.

After reading this guide, you will know:

- how to declare a composite, and make one only through `build`;
- when a value belongs in a group of columns, in a JSON document, or in a table of its own;
- how to keep a snapshot, a bounded map, or one of several shapes in a document;
- how a query reads a group as one value, and a path into a document with its type;
- how to change a document's shape without breaking the rows that hold the old one.

Before you start: you know [Named Queries and Generated Code](named-queries.md) and [Domain Models](domain-models.md).

## A composite is a value type declared once

A composite is declared with `Punch.composite`: its name and its fields, each with a type. The reference app's postal address is used by several entities of the billing slice, so it is declared in the slice's `composites.cr`:

```crystal source=reference/app/billing/composites.cr
# app/billing/composites.cr
# Composites several entities of billing use (lib/punch/docs/composites.md).
# Read by `punch db:generate`, which writes them into composites.gen.cr.

# A postal address: where an organization does business.
Punch.composite Billing::Address,
  street: Punch::NonEmptyString,
  postal_code: Punch::NonEmptyString,
  city: Punch::NonEmptyString,
  country: Punch::NonEmptyString
```

`punch db:generate` reads the declaration with Crystal's parser and writes the struct into `composites.gen.cr` beside it: a getter per field, equality by fields, JSON for answers, and a JSON Schema for `openapi.json`. A composite that only one entity uses is declared in that entity's `columns.cr` instead, next to the table that stores it.

Behaviour goes in a file named after the composite, which reopens the struct. The reference app writes an address as an envelope shows it:

```crystal source=reference/app/billing/address.cr
# app/billing/address.cr
struct Billing::Address
  # The address as it is written on an envelope, one line each.
  def lines : Array(String)
    [street.value, "#{postal_code} #{city}", country.value]
  end
end
```

A composite has no public `new`. `Billing::Address.build(street: …, …)` returns `Billing::Address | Punch::Invalid`, after checking every field's bounds and, when the composite defines one, its own rule across fields (`def self.check(value : self) : Punch::Invalid?`). `copy_with` checks the same. Reads from the database run the same checks, so no invalid address exists anywhere in the program.

## Building one from an input

A composite is a stored type, not an input. An operation reads its input as usual and builds the composite from it. The reference app's billing profile form sends four fields; `Update` builds the address and answers a refusal like any other:

```crystal source=reference/app/billing/profiles/operations/update.cr select=Billing::Profiles::Update#call bare
# app/billing/profiles/operations/update.cr
module Billing::Profiles
  # ...
  struct Update < Punch::Command
    # ...

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Update)) : Output
      organization = actor.organization || return NoProfile.new
      address = Billing::Address.build(street: input.street, postal_code: input.postal_code, city: input.city, country: input.country)
      # Four fields and no rule of its own: only too long a whole refuses it.
      return Punch::Rejection.new(Punch::Rejection::Path.new, address) if address.is_a?(Punch::Invalid)

      now = Time.utc
      record = if existing = Table.find(db, organization.id)
                 Table.update(db, existing.copy_with(address: address, updated_at: now))
               else
                 # None in this transaction, so the key is free.
                 Punch.cannot_violate(Table.insert(db, organization_id: organization.id, address: address, updated_at: now))
               end
      record ? Profile.new(record) : NoProfile.new
    end
  end
end
```

Each field is already a parsed domain primitive here, so `build` can only fail on what the composite checks as a whole. The `Punch::Rejection` at the empty path becomes a 422 with the error on the form, as for any rejected input ([Results, Errors, and Status Codes](results-errors-and-status-codes.md#statuses-come-from-the-types)).

## Where a composite is stored

A composite is stored in one of two ways, and some values are better off as a table of their own:

| The value | Store it as |
|---|---|
| A value object on a row that queries filter, index, or reference other rows from | a group of columns |
| A snapshot frozen at a moment, such as whom an invoice was billed to | a JSON document |
| A small list or map owned by its row and never queried per element | a JSON document, with a bound |
| One of several shapes, such as a card or a transfer | a JSON document |
| A list queried per element, referenced from elsewhere, edited concurrently, or unbounded | a child table, not a composite |
| Data whose shape the app does not own, such as a webhook's body | text, not a composite |

## A group of columns

A group stores each field in a column of its own, named by a prefix and the field. The reference app's billing profiles keep the organization's address that way:

```sql source=reference/db/migrations/20261102191115_create_billing_profiles.sql
-- db/migrations/20261102191115_create_billing_profiles.sql
-- An organization's billing profile: its address, a group of columns
-- holding a Billing::Address (lib/punch/docs/composites.md).
CREATE TABLE billing_profiles (
  organization_id     INTEGER PRIMARY KEY REFERENCES organizations (id),
  address_street      TEXT    NOT NULL,
  address_postal_code TEXT    NOT NULL,
  address_city        TEXT    NOT NULL,
  address_country     TEXT    NOT NULL,
  updated_at          TEXT    NOT NULL
) STRICT;
```

```crystal source=reference/app/billing/profiles/columns.cr
# app/billing/profiles/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "billing_profiles", Billing::Profiles,
  organization_id: Accounts::Organizations::ID,
  address: {type: Billing::Address, columns: "address_"},
  updated_at: Time
```

`columns: "address_"` maps the four `address_` columns to one field, so the record holds `address : Billing::Address`, and `Table.insert` and `update` take the composite. The columns are plain columns: indexes, foreign keys, `CHECK`s, and migrations work as for any other. A field that is not nilable needs a `NOT NULL` column.

A query that selects every column of a group gets the group back as one value. The invoice pages show the profile's address as the invoice's sender:

```sql source=reference/app/billing/invoices/queries.sql select=Sender
-- app/billing/invoices/queries.sql
-- name: Sender :one
-- The address an invoice is sent from: its organization's billing
-- profile, if it has one. All of the group's columns, so it reads as one
-- Billing::Address.
SELECT billing_profiles.address_street, billing_profiles.address_postal_code,
  billing_profiles.address_city, billing_profiles.address_country
FROM invoices JOIN billing_profiles ON billing_profiles.organization_id = invoices.organization_id
WHERE invoices.id = :invoice_id;
```

The generated row has one field, `address : Billing::Address`. A query that selects only some of the columns gets them as separate fields, each with its field's type, and a condition on one (`WHERE address_city = :city`) takes a `Punch::NonEmptyString`.

A nilable group (`{type: Billing::Address?, columns: "billing_"}`) is absent when all its columns are `NULL`. Its table needs a `CHECK` that keeps the required columns all `NULL` or all set; `punch db:generate` refuses the mapping without one and prints the `CHECK` to add ([Composites: stored as a group of columns](../composites.md#stored-as-a-group-of-columns)).

An uploaded file is kept the same way. `Punch::Upload::File` and its three siblings are composites Punch ships, which `columns.cr` maps without declaring anything ([Claiming the file](uploading-files.md#claiming-the-file)).

## A snapshot in a JSON document

A document stores the whole composite as one JSON object in one column. It suits a value that is kept as it was. A sent invoice keeps whom it billed, so a later change to the customer changes no invoice already sent:

```crystal source=reference/app/billing/invoices/columns.cr select=Billing::Invoices::BilledTo
# app/billing/invoices/columns.cr
# Who a sent invoice bills, as the customer was when it was sent: kept with
# the invoice, encrypted as a whole, so a later edit of the customer
# changes no sent invoice (lib/punch/docs/composites.md).
Punch.composite Billing::Invoices::BilledTo,
  customer_id: Billing::Customers::ID,
  name: Punch::NonEmptyString,
  company_name: Punch::NonEmptyString?,
  address: Punch::NonEmptyString?,
  tax_id: Billing::Customers::TaxID?

# ...
```

The column maps it as `billed_to: Punch::Encrypted(Billing::Invoices::BilledTo)`, since a name, an address, and a tax ID are personal data. Encrypted as a whole, the document is ciphertext, so its column is a `BLOB` without a `CHECK`:

```sql source=reference/db/migrations/20261102183822_add_invoice_billed_to.sql
-- db/migrations/20261102183822_add_invoice_billed_to.sql
-- Who a sent invoice bills, as the customer was when it was sent: a
-- Billing::Invoices::BilledTo document, encrypted as a whole (ciphertext,
-- so no CHECK). Invoices sent before have none.
ALTER TABLE invoices ADD COLUMN billed_to BLOB;
```

`Send` builds the snapshot from the customer when it sends the invoice, and the invoice's state holds it from then on ([Domain Models](domain-models.md)). The customer ID inside the document is a reference as it was: no foreign key keeps it current, which is what a snapshot wants.

## Bounded lists and maps

A document may hold an array or a map, and each declares its bound. The examples app prices each product per unit, in at most three currencies:

```crystal source=docs/guides/examples/app/billing/products/columns.cr
# app/billing/products/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

# What one unit of a product costs, per currency: at most three, kept
# with the product and never queried per currency.
Punch.composite Billing::Products::Pricing,
  unit: Punch::NonEmptyString,
  prices: {type: Hash(Punch::Currency, Punch::Money), max: 3}

Punch.table "products", Billing::Products,
  id: Billing::Products::ID,
  name: Punch::NonEmptyString,
  pricing: Billing::Products::Pricing
```

A plain document is `TEXT`, and a `CHECK` keeps it a JSON object; `punch db:generate` requires it:

```sql source=docs/guides/examples/db/migrations/20261102201205_create_products.sql
-- db/migrations/20261102201205_create_products.sql
-- What the app sells, priced per unit in each currency it is sold in.
-- The pricing is one JSON document (Billing::Products::Pricing), kept an
-- object by its CHECK.
CREATE TABLE products (
  id      INTEGER PRIMARY KEY,
  name    TEXT    NOT NULL UNIQUE,
  pricing TEXT    NOT NULL CHECK (json_valid(pricing) AND json_type(pricing) = 'object')
) STRICT;
```

`max: 3` is checked by `build` and on every read, and shows in the JSON Schema as `maxProperties` (`maxItems` for an array). A map's keys are text or a domain primitive stored as text, here `Punch::Currency`. The Command builds the pricing from a list of prices in its input and answers `too_many` at `prices` when there are more than three:

```crystal source=docs/guides/examples/app/billing/products/operations/create.cr select=Billing::Products::Create#call bare
# app/billing/products/operations/create.cr
module Billing::Products
  # ...
  struct Create < Punch::Command
    # ...

    def call(input : Input, db : Punch::Writer, _actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      prices = input.prices.to_h { |price| {price.currency, price.amount} }
      pricing = Pricing.build(unit: input.unit, prices: prices)
      # More currencies than the declared bound: `too_many`, at `prices`.
      return Punch::Rejection.new(Punch::Rejection::Path{"prices"}, pricing) if pricing.is_a?(Punch::Invalid)

      case product = Table.insert(db, name: input.name, pricing: pricing)
      in Record    then Created.new(product.id, product.name, product.pricing)
      in NameTaken then product
      end
    end
  end
end
```

```crystal source=docs/guides/examples/spec/billing/products/create_spec.cr select="Billing::Products::Create keeps a product's prices in one document, and refuses more currencies than the bound"
# spec/billing/products/create_spec.cr
describe Billing::Products::Create do
  it "keeps a product's prices in one document, and refuses more currencies than the bound" do
    client = AccountsSpec.client
    prices = [{currency: "EUR", amount: 12_000}, {currency: "CHF", amount: 11_500}]
    created = client.post(Billing::Products::Create.path, json: {name: "Consulting", unit: "hour", prices: prices})
    created.status.should eq(HTTP::Status::CREATED)
    created.json["pricing"].should eq(JSON.parse(%({"unit": "hour", "prices": {"EUR": 12000, "CHF": 11500}})))

    four = prices + [{currency: "USD", amount: 13_000}, {currency: "GBP", amount: 10_500}]
    refused = client.post(Billing::Products::Create.path, json: {name: "Workshop", unit: "day", prices: four})
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.json["errors"][0]["path"].should eq(JSON.parse(%(["prices"])))
    refused.json["errors"][0]["code"].should eq("too_many")
  end

  # ...
end
```

The stored document is the composite's declared fields under their names, with nilable fields left out when `nil`: `{"unit":"hour","prices":{"EUR":12000,"CHF":11500}}`. A document is at most 16 KiB of JSON and nests at most 32 levels deep, unless its declaration says `max_bytes:` or `max_depth:`. Elements of an array have no identity: changing one writes the document again. A list whose elements need an identity, a query, or edits of their own is a child table.

## One of several shapes

A polymorphic composite is one of several member composites, told apart by a key in the stored document. A customer of the examples app pays by card or by bank transfer:

```crystal source=docs/guides/examples/app/billing/payment_methods/columns.cr select=Billing::PaymentMethods::Method,Billing::PaymentMethods::Card,Billing::PaymentMethods::Transfer
# app/billing/payment_methods/columns.cr
# A card or a transfer, told apart by `kind` in the stored document.
Punch.composite Billing::PaymentMethods::Method,
  discriminator: "kind",
  one_of: {card: Billing::PaymentMethods::Card, transfer: Billing::PaymentMethods::Transfer}

# A card, by its brand and the last four digits of its number; the rest
# stays with the payment provider.
Punch.composite Billing::PaymentMethods::Card,
  brand: Punch::NonEmptyString,
  last4: Punch::NonEmptyString

# A bank transfer from an account, with the reference the customer puts
# on it, if any.
Punch.composite Billing::PaymentMethods::Transfer,
  iban: Punch::NonEmptyString,
  reference: Punch::NonEmptyString?

# ...
```

`Billing::PaymentMethods::Method` is the union `Card | Transfer`, so a `case … in` over it must handle both, and the compiler says which one is missing:

```crystal source=docs/guides/examples/spec/billing/payment_methods/payment_methods_spec.cr select="Billing::PaymentMethods reads each method back as its own type, told apart by its kind"
# spec/billing/payment_methods/payment_methods_spec.cr
# ...

describe Billing::PaymentMethods do
  it "reads each method back as its own type, told apart by its kind" do
    add("ada@example.org", card)
    add("ada@example.org", transfer)
    methods = Punch::Spec.db.read { |db| Billing::PaymentMethods::Queries.of_customer(db, customer_email: ExamplesSpec.parse(Punch::Email, "ada@example.org")) }
    endings = methods.map do |row|
      case method = row.method
      in Billing::PaymentMethods::Card     then "#{method.brand} ending #{method.last4}"
      in Billing::PaymentMethods::Transfer then "transfer from …#{method.iban.value[-4..]}"
      end
    end
    endings.should eq(["Visa ending 4242", "transfer from …3000"])
  end

  # ...
end
```

A stored member writes its tag under the key, `{"kind":"card","brand":"Visa","last4":"4242"}`, and a read picks the member by it. A tag the composite does not know makes the row unreadable (`unknown_member`). Answers show the tag too, and `openapi.json` describes the composite as a `oneOf` with a `discriminator`, so a generated client gets a typed union. Polymorphic composites are stored only as documents.

## Paths in queries

A query can read a path into a plain document, and the path gets its type from the composite. The examples app lists a customer's card brands:

```sql source=docs/guides/examples/app/billing/payment_methods/queries.sql select=CardBrands
-- app/billing/payment_methods/queries.sql
-- name: CardBrands :many
-- The brands of a customer's cards: a path into the document, typed from
-- the composite. `brand` is nilable, since only cards have one.
SELECT id, method ->> '$.brand' AS brand
FROM payment_methods
WHERE customer_email = :customer_email AND method ->> '$.kind' = 'card'
ORDER BY id;
```

`brand` is a `Punch::NonEmptyString?`: nilable, because only cards have a brand. A path is nilable wherever the document may lack it, also for an array element, a map entry, a nilable field, or a field with a default (older documents may not have it). A path to a nested composite gives that composite. A parameter compared with a path takes the path's type.

Paths only read: a document is written whole, through `Table.insert`, `update`, or a parameter assigned to the column. A path read often can get a generated column with an index ([Composites: paths in queries](../composites.md#paths-in-queries)). A path into an encrypted document does not exist, since the column holds ciphertext.

## Changing a document's shape

A document outlives the release that wrote it, and a rollback lets an older release read what a newer one wrote. Its shape follows the same rules as job payloads: `punch jobs:lock` records each document's shape in the `documents` section of `payloads.lock.json`, and `punch check` compares against it ([Background Jobs](background-jobs.md#changing-a-payload)).

- **Compatible:** adding a nilable field, or one with a default (`country: {type: Punch::NonEmptyString, default: "DE"}`), which fills the field in older documents.
- **A new version:** removing a required field, renaming one, or changing its type. Declare `version: 2, from: {1 => V1}` with the old shape kept as a frozen type, whose `upgrade` turns it into the current one. Reads upgrade old documents; `punch db:upgrade`, and a nightly job, rewrite them.
- **Keys a newer release wrote are kept.** A document read and written back with `copy_with` keeps the keys its type does not know, so a rollback does not erase a newer release's fields.

A group of columns changes by migrations, like any column, and has no versions ([Migrations](migrations.md)).

## Common mistakes

**A plain document column without its `CHECK`.** Without it, the column could hold any text. `punch db:generate` refuses the mapping and prints the `CHECK` to add:

```text message=src/punch/query_gen/groups.cr
products.pricing holds a JSON document, so a CHECK keeps it one; declare the column with: CHECK (json_valid(pricing) AND json_type(pricing) = 'object')
```

Add it in the migration that creates the column. An existing table gains a `CHECK` only by a rebuild ([Migrations](migrations.md)).

**An unbounded list or map.** A document has to stay small enough to read whole on every load. An array or a map without `max:` is refused:

```text message=src/punch/query_gen/composites.cr
Billing::Products::Pricing.prices: a map is bounded: {type: Hash(K, V), max: N}
```

Pick the largest number the domain allows. When there is none, the list is a child table.

**A path the composite does not declare.** A typo in a path, or a field that was renamed, would read `NULL` forever. The generator refuses it instead:

```text message=src/punch/query_gen/paths.cr
query Prices: '$.price': Billing::Products::Pricing has no field price
```

**Writing the struct by hand, or calling `new`.** The generated struct is the declaration's; there is no public `new`. Build one with `build` or `copy_with`, and handle `Punch::Invalid`.

**Rescuing `Punch::Database::RowError` to read past a bad document.** A stored document that does not parse is a bug or damage, and its error names the table, column, row, and path. Fix the data or the declaration; `punch db:audit` counts each composite's documents per version.

## Limits

- A group holds no lists, maps, or polymorphic composites; those are stored as documents.
- A nilable group with an encrypted field cannot be mapped yet: its `CHECK` would read the encrypted column.
- A plain document cannot hold an encrypted field: encrypt the whole document.
- Paths only read, and only plain documents.
- Typed IDs inside a document have no foreign key.

## Rules

- Declare composites with `Punch.composite`, in the slice's `composites.cr` or the entity's `columns.cr`; put behaviour in the file named after the composite. ([A composite is a value type declared once](#a-composite-is-a-value-type-declared-once))
- Make one only with `build` or `copy_with`, and handle `Punch::Invalid`. ([Building one from an input](#building-one-from-an-input))
- Store a value that queries filter or reference as a group; a snapshot, a small owned list, or one of several shapes as a document; anything queried per element as a child table. ([Where a composite is stored](#where-a-composite-is-stored))
- Bound every array and map. ([Bounded lists and maps](#bounded-lists-and-maps))
- Encrypt personal data in a document as `Punch::Encrypted(T)`. ([A snapshot in a JSON document](#a-snapshot-in-a-json-document))
- Give a plain document its `json_valid` `CHECK`, and a nilable group the `CHECK` the generator prints. ([A group of columns](#a-group-of-columns))
- Change a document's shape compatibly, or raise its version with a frozen type; never edit a frozen type. ([Changing a document's shape](#changing-a-documents-shape))

## Reference

- [Composites](../composites.md): every option, field type, bound, and error code.
- [Queries: domain types](../queries.md#domain-types-columnscr): how `columns.cr` maps columns.
- [Background jobs: payloads across deploys](../jobs.md#payloads-across-deploys): the rules documents share with payloads.
