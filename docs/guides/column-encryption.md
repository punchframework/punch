# Column Encryption and Blind Indexes

Applies to Punch 0.1.

A SQLite database is a file, and a file gets copied: to a backup, to a replica, to a laptop for debugging. Column encryption keeps the personal data in such a copy unreadable. You declare a column as encrypted, and generated code encrypts on write and decrypts on read, so a value is in no database file, backup, or replica in readable form. Encrypted values look different every time, so the database can no longer compare them. A blind index brings back the one comparison most apps need: finding a row by an exact value, and keeping values unique.

After reading this guide, you will know:

- what column encryption protects against, and what it does not;
- how to encrypt a new column, and how values reach and leave it;
- what stops working on an encrypted column, and why the generator refuses it;
- how to find and keep unique an encrypted value with a blind index;
- how to convert a column that already holds plaintext, over three releases;
- how keys rotate under encrypted data, and how to test all of it.

Before you start: you know [Named Queries and Generated Code](named-queries.md), [Migrations](migrations.md), and [Credentials and Keys](credentials-and-keys.md). The examples come from the reference app's `customers` table, which encrypts an address, a tax number, and an email address.

## What encryption protects

An encrypted column protects data at rest. Someone who gets `primary.db`, a replica, or a backup reads ciphertext, and so does `punch db:shell`. Each column has its own key, derived from the app's key ring for the purpose `column:<table>.<column>`, and values are encrypted with AES-256-GCM.

It does not protect against the running app. The app holds the keys, so a bug in a policy, or anyone with the key ring, reaches the values. The bucket's encryption at rest, which [Backup and Restore](backup-and-restore.md) asks for, protects against a different loss and does not replace this: it keeps a stolen disk at the provider unreadable, while an encrypted column stays unreadable to anyone who can read the replica itself.

Encrypt personal data and stored secrets. Leave the rest: an encrypted column gives up comparing, sorting, and searching, so a name that people search for stays plaintext. The reference app encrypts a customer's address, tax number, and email address, and keeps the name in the clear so that the list can sort by it.

## Encrypting a new column

An encrypted column is declared `BLOB`, since a `STRICT` `TEXT` column cannot hold ciphertext:

```sql source=reference/db/migrations/20261030120000_add_address_to_customers.sql
-- db/migrations/20261030120000_add_address_to_customers.sql
-- A customer's postal address, for invoices. Personal data, so it is
-- encrypted: app/billing/customers/columns.cr maps it as
-- Punch::Encrypted(Punch::NonEmptyString), and the column holds only
-- ciphertext (lib/punch/docs/queries.md#encrypted-columns).
ALTER TABLE customers ADD COLUMN address BLOB;
```

`columns.cr` maps it as `Punch::Encrypted(T)`, where `T` is the type of the value:

```crystal source=reference/app/billing/customers/columns.cr
# app/billing/customers/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "customers", Billing::Customers,
  id: Billing::Customers::ID,
  organization_id: Accounts::Organizations::ID,
  name: Punch::NonEmptyString,
  company_name: Punch::NonEmptyString,
  address: Punch::Encrypted(Punch::NonEmptyString),
  tax_id: Punch::Encrypted(Billing::Customers::TaxID),
  tax_id_index: Punch::BlindIndex.of(:tax_id),
  email_encrypted: Punch::Encrypted(Punch::Email),
  email_index: Punch::BlindIndex.of(:email_encrypted),
  created_at: Time,
  locale: Punch::LocaleTag
```

`T` is a domain primitive, `Time`, `Bool`, a composite, or a stored type such as `String`. Its parsing still runs when a value is read, so a stored address is a `Punch::NonEmptyString` again, or a row error.

Generated code encrypts on write and decrypts on read. A record holds the value as `Punch::Secret(T)`, which prints as `[REDACTED]` in logs, spans, and error reports and does not serialize to JSON. So a write takes a `Secret`, and a read gives one. `Create` wraps what the input parsed:

```crystal source=reference/app/billing/customers/operations/create.cr select=Billing::Customers::Create#call
# app/billing/customers/operations/create.cr
module Billing::Customers
  # ...

  # Adds a customer to the organization the actor works in. Each
  # organization's customers have unique email addresses and tax numbers.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Create < Punch::Command
    # ...

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Create)) : Output
      if rejection = Invoicing::Languages.check(input.locale)
        return rejection
      end

      case created = Table.insert(db, organization_id: actor.organization_id, name: input.name, company_name: input.company_name, email_encrypted: Punch::Secret.new(input.email),
        address: input.address.try { |address| Punch::Secret.new(address) }, tax_id: input.tax_id.try { |tax_id| Punch::Secret.new(tax_id) },
        created_at: Time.utc, locale: input.locale)
      in Record              then Created.new(Customer.new(created))
      in EmailEncryptedTaken then created.rejection("email") # named after the encrypted column; 422 at `email`
      in TaxIdTaken          then created                    # 422 at `tax_id`
      end
    end
  end
end
```

The result that shows the address unwraps it, on purpose and in one place:

```crystal source=reference/app/billing/customers/results.cr select=Billing::Customers::Customer
# app/billing/customers/results.cr
module Billing::Customers
  # A customer as the API shows it.
  @[Punch::Status(200)]
  struct Customer
    include JSON::Serializable

    getter id : ID
    getter organization_id : Accounts::Organizations::ID
    # The contact person.
    getter name : Punch::NonEmptyString
    getter company_name : Punch::NonEmptyString?
    getter email : Punch::Email
    # The postal address invoices go to.
    getter address : Punch::NonEmptyString?
    # The VAT or tax number, without spaces.
    getter tax_id : TaxID?
    # The language of the customer's mail, if one was chosen.
    getter locale : Punch::LocaleTag?
    # The company name if there is one, else the contact's name.
    getter display_name : String
    getter created_at : Time

    def initialize(record : Record)
      @id = record.id
      @organization_id = record.organization_id
      @name = record.name
      @company_name = record.company_name
      @email = record.email_encrypted.unwrap
      @address = record.address.try(&.unwrap) # decrypted for the response
      @tax_id = record.tax_id.try(&.unwrap)
      @locale = record.locale
      @display_name = record.display_name
      @created_at = record.created_at
    end
  end

  # ...
end
```

`unwrap` is the line a reviewer looks for: it says that this value leaves its protection here, for this reader.

## What stops working on an encrypted column

Each write encrypts with a fresh nonce, so the same value is stored differently every time. Nothing the database does by comparing stored bytes can work, and `punch db:generate` refuses what would compare ciphertext instead of letting it return nothing:

- a unique key or any other index on the column;
- a parameter or another column compared with it: `WHERE address = :address`;
- `LIKE`, `GLOB`, `IN`, and `BETWEEN` on it;
- sorting or grouping by it, in `ORDER BY`, `GROUP BY`, a `-- order` clause, or a page;
- assigning it to another column;
- a `CHECK` constraint that reads it. Rules on the value live in `T` and the input instead.

An expression over an encrypted column, such as `coalesce(address, ...)`, is ciphertext too, typed `Bytes`, and nothing checks what such an expression is compared with.

## Finding an encrypted value: blind indexes

A blind index is a second `BLOB` column holding a keyed hash of the value. Equal values have equal hashes, so an index on it finds a row by the exact value, and a unique index keeps values unique, without anything being decrypted. The reference app's tax number has one, unique per organization:

```sql source=reference/db/migrations/20261030204159_add_tax_id_to_customers.sql
-- db/migrations/20261030204159_add_tax_id_to_customers.sql
-- A customer's VAT or tax number. For a sole trader it is personal data, so
-- it is encrypted, and found through a blind index: tax_id_index holds a
-- keyed hash of the number (app/billing/customers/columns.cr,
-- lib/punch/docs/queries.md#blind-indexes). The unique index keeps each
-- organization's numbers unique and serves the list's tax_id filter.
ALTER TABLE customers ADD COLUMN tax_id BLOB;
ALTER TABLE customers ADD COLUMN tax_id_index BLOB;
CREATE UNIQUE INDEX customers_by_tax_id ON customers (organization_id, tax_id_index);
```

The mapping names the encrypted column it hashes, `tax_id_index: Punch::BlindIndex.of(:tax_id)` in the `columns.cr` above. The generated `Table` then writes the hash itself: `insert` and `update` take no argument for it, and the record has no field for it.

A query compares it with a parameter, column first. The parameter takes the encrypted column's type, `TaxID`, not a `Secret`:

```sql illustrative="the Page query of reference/app/billing/customers/queries.sql, without its doc comment"
SELECT * FROM customers
WHERE organization_id = :organization_id
-- when tax_id: AND tax_id_index = :tax_id
-- order created: ORDER BY id
-- order name: ORDER BY name, id
```

A unique index gives a violation named after the encrypted column. `TaxIdTaken` answers 422 with `taken` at the field `tax_id`, the same as for a plain unique column, and `Create` above returns it as it is.

The hash is over the stored form of the value, so a type that normalizes finds a value however it was written. `TaxID` drops spaces and capitalizes:

```crystal source=reference/app/billing/customers/types.cr select=Billing::Customers::TaxID
# app/billing/customers/types.cr
module Billing::Customers
  # ...

  # A VAT or tax number, `DE123456789`: a country code and 2 to 13
  # letters or digits, kept without spaces and in capitals, so the same
  # number written two ways is one value. That matters for its blind
  # index, which finds only equal values.
  struct TaxID
    include Punch::Primitive(String)

    FORMAT = /\A[A-Z]{2}[A-Z0-9]{2,13}\z/

    def self.json_schema
      {pattern: "^ *[A-Za-z] *[A-Za-z]( *[A-Za-z0-9]){2,13} *$"}
    end

    def self.parse(raw : String) : self | Punch::Invalid
      normal = raw.delete(' ').upcase(Unicode::CaseOptions::ASCII)
      FORMAT.matches?(normal) ? new(normal) : Punch::Invalid.new("invalid_tax_id")
    end
  end
end
```

So `de 123 456 789` finds `DE123456789`. A hash finds the whole value only, never a part, a prefix, or a range.

> [!WARNING]
> Equal values have equal hashes, so anyone with the database file sees which rows share a value. Never index a value with few possible values, such as a `Bool` or a country: its hashes are then as good as the values.

## Encrypting a whole document

A composite stored as a JSON document is encrypted as a whole, as `Punch::Encrypted(Billing::Invoices::BilledTo)`. A plain document cannot hold an encrypted field, and a path into an encrypted document reads ciphertext, so the generator refuses both. [Composites](composites.md#a-snapshot-in-a-json-document) shows it with the customer details a sent invoice keeps.

## Converting a plaintext column

A column that already holds personal data becomes an encrypted one over three releases, so that no process meets a row it cannot read while two of them run during a deploy ([Evolving a Live App](evolving-a-live-app.md)). The ciphertext goes into a new `BLOB` column beside the plaintext one. The reference app converted `customers.email` this way.

**Release 1: read either, write both.** A migration adds the encrypted column, and the blind index with its unique index:

```sql source=reference/db/migrations/20261030214641_encrypt_customer_emails.sql
-- db/migrations/20261030214641_encrypt_customer_emails.sql
-- Converting customers.email to an encrypted column, first of three
-- releases (lib/punch/docs/queries.md#converting-a-plaintext-column): the
-- ciphertext goes in email_encrypted, with its blind index for the unique
-- key and lookups. app/billing/customers/columns.cr maps it with
-- from(:email), so this release reads either and writes both, and
-- `punch db:encrypt` (or the nightly job) converts the rows written before.
ALTER TABLE customers ADD COLUMN email_encrypted BLOB;
ALTER TABLE customers ADD COLUMN email_index BLOB;
CREATE UNIQUE INDEX customers_by_email_index ON customers (organization_id, email_index);
```

`columns.cr` maps it with `from`, naming the plaintext column:

```crystal illustrative="columns.cr as it was in release 1"
email_encrypted: Punch::Encrypted(Punch::Email).from(:email),
email_index: Punch::BlindIndex.of(:email_encrypted)
```

The record has one field, `email_encrypted`, read from the ciphertext when the row has it, and otherwise from the plaintext. `Table.insert` and `update` write both, so the release before still reads every row. After the deploy, convert the rows written before:

```console
$ punch db:encrypt
$ punch db:audit
```

`db:audit` counts what is left, as in `customers.email_encrypted: converting from email, 12 only in plaintext, 340 plaintext copies left`. Do not start release 2 until nothing is only in plaintext.

**Release 2: clear the plaintext.** Map it with `clear: true`:

```crystal illustrative="columns.cr as it was in release 2"
email_encrypted: Punch::Encrypted(Punch::Email).from(:email, clear: true),
```

Generated code now leaves `email` out entirely, and refuses any query that names it, or selects it with `*`, so the next release can drop the column. It writes `NULL` by leaving it out, so the column has to be nullable first, and any unique key on it has to go. Both take a migration that rebuilds the table, in this release; the reference app's is `20261030221650_clear_customer_emails.sql`. After the deploy, `punch db:encrypt` clears the remaining plaintext. It checks each row first: a row whose ciphertext does not hold the plaintext is reported as `not_decrypting` or `plaintext_differs`, and keeps both until you decide which is right.

**Release 3: drop it.** A migration drops the column, and `columns.cr` maps `email_encrypted: Punch::Encrypted(Punch::Email)` without `from`. The field stays named `email_encrypted`, because its key is derived from the column's name. A result struct or input can still call it `email`.

**Afterwards, remove what is left.** A database written before Punch turned on `secure_delete`, or by another tool, may still hold the plaintext in free pages. Rebuild the file once at a quiet time, since `VACUUM` blocks writes while it runs ([Queries: Converting a plaintext column](../queries.md#converting-a-plaintext-column)). Backups are not rewritten: old generations keep the plaintext until their retention removes them, and a restore from one brings it back.

## Rotating keys under encrypted data

A write uses the key ring's signing key, and a read accepts every key of the ring, so a rotation breaks nothing by itself. A value stays under the key that wrote it until its row is written again, and a key cannot retire while values still need it:

1. Rotate and promote as usual ([Rotating keys without breaking links](credentials-and-keys.md#rotating-keys-without-breaking-links)).
2. Run `punch db:encrypt`, which re-encrypts every value under the signing key and hashes every blind index again. It runs in batches of 500 rows, each one short transaction, so it is safe beside the running app. A recurring job does the same every night; after a rotation, run the command rather than wait.
3. Run `punch db:audit`. When it counts nothing under the old key, retire the key.

During a rotation, uniqueness holds per key: the same value hashed under two keys is two index values. `db:encrypt` reports a row whose new hash another row already has as `taken`. Merge or change those rows, and run it again.

A value that cannot be decrypted raises `Punch::Database::RowError` with the reason `not_decrypting`: a value moved from another column, damaged, or written under a key the ring no longer has. Like every row error, it names the table, column, and row, never the value.

> [!WARNING]
> `punch keys:rotate --revoke` replaces every key at once, so every encrypted column becomes unreadable. It is a last resort after a compromise. So is renaming an encrypted column or its table: the key is derived from those names, and existing values stop decrypting.

## Testing encrypted columns

Specs need a key ring, which `Punch::Spec.credentials` in the spec helper loads. `be_encrypted_for` checks that a value read straight from the database is ciphertext this column's key opens, and `Punch::Stored.blind_index` gives the hash a row should hold:

```crystal illustrative="the first example of reference/spec/billing/customers/tax_id_spec.cr"
it "is stored encrypted, with its blind index, and shown without spaces" do
  client = AccountsSpec.client
  response = create(client, "de 123 456 789")
  response.json["customer"]["tax_id"].should eq("DE123456789")
  id = id_of(response)
  stored("tax_id", id).should be_encrypted_for("customers", "tax_id")
  String.new(stored("tax_id", id) || fail "no tax number").should_not contain("123456789")
  stored("tax_id_index", id).should eq(Punch::Stored.blind_index(Billing::Customers::TaxID.parse("DE123456789").as(Billing::Customers::TaxID), "customers", "tax_id_index"))
  create(client, nil).json["customer"]["tax_id"]?.should be_nil
end
```

Check the stored bytes in at least one example per column. A column whose mapping is lost would still pass every example that only reads through the app.

## Common mistakes

**Declaring the column `TEXT`.** Ciphertext is bytes, and `db:generate` refuses the mapping:

```text message=src/punch/query_gen/mapping.cr
customers.address is TEXT, but an encrypted column holds ciphertext; declare it BLOB
```

**A unique key on the encrypted column.** It would never find an equal value, so it would keep nothing unique:

```text message=src/punch/query_gen/mapping.cr
tax_id is encrypted, so the unique key on customers.tax_id compares ciphertext, which differs for every write and never finds an equal value; drop it
```

Add a blind index, and put the unique index on that.

**Comparing it with a parameter.** Do not work around this by selecting all rows and filtering in Crystal, which decrypts the whole table for every lookup:

```text message=src/punch/query_gen/analyzer.cr
param tax_id: compared with customers.tax_id, which is encrypted; its stored values are ciphertext, different every time, so they never equal a value
```

Compare the blind index: `tax_id_index = :tax_id`.

**Sorting a page by it.** Ciphertext has no order, so a list sorts by another column:

```text message=src/punch/query_gen/keyset.cr
sorts by tax_id, which is encrypted; ciphertext has no order
```

**Unwrapping early.** A `Secret` unwrapped in a store or passed around as a `String` is an ordinary value again, and ends up in a log. Unwrap where the value is shown, in the result that shows it.

**Dropping the plaintext column in one release.** The release before still reads it during the deploy, and a row without ciphertext is lost. Take the three releases.

**Retiring a key before the audit is clean.** Values under it stop decrypting. Run `punch db:encrypt`, and retire when `punch db:audit` counts nothing under the key.

**A blind index on a type that does not normalize.** `Ada@Example.org` and `ada@example.org` are then two values, and neither finds the other. Normalize in `T`'s `parse`.

## Limits

- Equality on a whole value is the only comparison on encrypted data. There is no prefix, range, or full-text search.
- The standard library has no additional authenticated data, so a value copied to another row of the same column still decrypts. A value copied to another column does not.
- Uniqueness through a blind index holds per key while a rotation runs.
- Backups keep whatever they held, so conversion does not reach old generations.
- Encrypted columns are for what a database row holds, a file's name among them ([A file with a private name](uploading-files.md#a-file-with-a-private-name)). The files themselves are the bucket's concern.

## Rules

- Declare an encrypted column `BLOB`, and map it as `Punch::Encrypted(T)`. ([Encrypting a new column](#encrypting-a-new-column))
- Unwrap a `Punch::Secret` only where the value is shown. ([Encrypting a new column](#encrypting-a-new-column))
- Find or keep unique an encrypted value only through a blind index. ([Finding an encrypted value: blind indexes](#finding-an-encrypted-value-blind-indexes))
- Never give a blind index to a value with few possible values. ([Finding an encrypted value: blind indexes](#finding-an-encrypted-value-blind-indexes))
- Normalize a value in its type before you hash it. ([Finding an encrypted value: blind indexes](#finding-an-encrypted-value-blind-indexes))
- Convert a plaintext column over three releases, and check each with `db:audit`. ([Converting a plaintext column](#converting-a-plaintext-column))
- Never rename an encrypted column or its table. ([Rotating keys under encrypted data](#rotating-keys-under-encrypted-data))
- Retire a key only when `db:audit` counts nothing under it. ([Rotating keys under encrypted data](#rotating-keys-under-encrypted-data))

## Reference

- [Queries: Encrypted columns](../queries.md#encrypted-columns), [blind indexes](../queries.md#blind-indexes), and [`db:encrypt`](../queries.md#converting-and-re-encrypting-dbencrypt): every rule and format.
- [Keys](../keys.md): the key ring, purposes, and rotating.
- [Persistence](../persistence.md): `secure_delete` and the database files.
- Next: [Evolving a Live App](evolving-a-live-app.md), for other changes that take several releases.
