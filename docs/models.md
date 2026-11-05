# Domain models

Learn it in: [Domain Models](guides/domain-models.md).

A model decides, an operation orchestrates. A model holds derived values, its own invariants, and its state transitions, and never receives a database handle. An operation loads, asks the model, saves, publishes events, and returns a result.

Punch has models in two tiers. Tier 1, behaviour on the generated record, is the default. Tier 2, one hand-written type per lifecycle state and a store, is for entities with a real lifecycle; the reference app's invoices are the worked example (`reference/app/billing/invoices/`).

## The outline of an entity

Every namespace directory under `app/` has a file beside it, named like it, that outlines the concept: `app/billing/customers.cr` for `app/billing/customers/`. That holds for entities (directories with their own tables), namespaces without tables (`app/accounts/sign_up.cr`), and slices (`app/billing.cr`). It is the canonical place to learn what the concept is before opening its parts.

```crystal
# An invoice is an organization's request that a customer pay for what
# it delivered: lines of work or goods, priced in one currency.
#
# It starts as a draft, which the organization may change or discard
# as it likes. Sending it to the customer makes it binding: ...
#
# Invoices are what the rest of billing turns on: a customer owes what
# its sent invoices add up to, and payments exist to settle them.
module Billing::Invoices
  # How long a customer has to pay a sent invoice.
  PAYMENT_TERM = 14.days
end
```

- **Meaning and purpose, in plain words.** What the entity is, what it is for, and how it stands among the other entities, as someone who knows the business would say it. Leave out what the code, the generated docs, and `punch routes` already tell: types, files, tables, events, policies. Those change with the code; the meaning rarely does, and an outline that repeats them goes stale.
- **At most the constants the domain names.** A constant whose value is a business fact (the payment term) may sit in the outline, documented, with a plain value: a number, string, symbol, range, or duration (`14.days`). Code uses it as `Billing::Invoices::PAYMENT_TERM`. No methods, types, requires, or computed constants (a cache, a regex): those go into the files under the directory. That keeps the outline a place to read, and it costs nothing to compile (measured on the reference app: warm rebuild and peak memory unchanged within noise).
- **The only doc comment on that module.** `crystal docs` keeps the last doc comment it reads for a reopened module, so another file's comment directly above `module Billing::Customers` would replace the outline: leave a blank line below a file's header comment. The generated require file loads outlines before the files under their directories (`docs/structure.md`).
- `Punch/NamespaceFile` reports a namespace directory without its outline (at its first file), an outline that is not one documented `module` of the right name, anything in it but documented plain constants, a doc comment on the module in another file, a type outside the namespace of its file's directory, and the placeholder `punch generate` writes into a new outline until it is replaced (`docs/tooling.md`).
- Keep it true: a change to what the entity means, or to a constant's business fact, changes its outline in the same commit.

The reference app's outlines: `app/billing.cr`, `app/billing/customers.cr`, `app/billing/invoices.cr`, `app/accounts/organizations.cr`, `app/accounts/sessions.cr`, and one beside each other directory.

## Choosing a tier

Start with the generated record. Move an entity to state types when one of these holds:

- its state decides which operations are allowed;
- it has rules that span itself and its child rows;
- the same status check has turned up in a second operation.

Stay with the generated record for reference data and for entities that are only created, shown, and edited. When unsure, stay with the first tier; moving up later is mostly contained in one slice.

| Kind of logic | Home |
|---|---|
| Belongs to one use case | The operation |
| About the thing itself, and needed by several operations | The model |
| Derivable by the database and needed in lists | SQL |

In the reference app, a customer is tier 1 (created, shown, edited; one derived value) and an invoice is tier 2 (only a draft may be revised, deleted, or sent; sending checks its lines).

## Tier 1: behaviour on the generated record

`punch db:generate` writes one `Record` per mapped table into `records.gen.cr` beside the entity's `columns.cr` (`docs/queries.md`). Behaviour goes in a hand-written file that reopens the struct. Its name is fixed, the way Crystal names any type's file: `Billing::Customers::Record` lives in `app/billing/customers/record.cr` (`src/` in an app without `app/`). The generated record's comment names that file:

```crystal
# app/billing/customers/records.gen.cr
module Billing::Customers
  # A row of `customers`, reused by every query that selects the whole row.
  # Its behaviour goes in `app/billing/customers/record.cr`, which reopens this struct.
  record Record, id : ID, name : Punch::NonEmptyString, company_name : Punch::NonEmptyString?, ...
```

```crystal
# app/billing/customers/record.cr
struct Billing::Customers::Record
  # The name invoices are addressed to: the company when there is one.
  def display_name : String
    (company_name || name).value
  end
end
```

- No mapping code: the model has the table's shape, and every query that returns whole rows returns it.
- Only methods: the record's fields come from the schema. None of them takes a database handle.
- The Ameba rule `Punch/RecordFile` reports a `struct …::Record` anywhere but its own file, so the pointer in the generated file is always right.

`punch db:generate --json` lists each mapped table with `behaviour` (the path) and `behaviour_exists`.

## Behaviour modules for list rows

Lists read narrow query rows, not records or state types. A rule needed by both, such as "overdue", goes in a module that names the fields it needs as abstract methods. A model includes it, and a query includes it in its row with an `-- include` line in the header:

```crystal
# app/billing/invoices/invoice.cr
module Billing::Invoices::Invoice
  module Due
    abstract def due_at : Time?

    def overdue?(now : Time) : Bool
      due = due_at
      due ? now > due : false
    end
  end

  record Sent, ..., due_at : Time do
    include Due
  end
end
```

```sql
-- name: Page :many
-- Invoices after the given ID with their customer's name and total, for lists.
-- include Billing::Invoices::Invoice::Due
SELECT invoices.id, invoices.status, ..., invoices.due_at
FROM invoices ...
```

The generated `Page::Row` then has `include Billing::Invoices::Invoice::Due`, and `row.overdue?(now)` is the same rule as `sent.overdue?(now)`.

- **Checked at compile time.** A row without one of the module's fields, or with a field of another type, does not compile: `abstract def Due#due_at() must be implemented by …::Page::Row`. A field may be narrower than the abstract method: `Sent#due_at : Time` satisfies `Time?`.
- **Require the module before the generated query file**, so the constant exists when the row includes it.
- `-- include` takes a module name; several lines include several modules. A query that returns whole records cannot include anything (the generator points to the record's behaviour file instead), and neither can one that returns no rows.
- Give the module only methods computed from its fields. Like a model, it never touches the database.

## Tier 2: state types and a store

Each lifecycle state is its own immutable type, and a transition is a method that returns the next state. Only a draft can be sent, so only `Draft` has `send`:

```crystal
# app/billing/invoices/invoice.cr
module Billing::Invoices::Invoice
  record Draft, id : Invoices::ID, customer_id : Customers::ID, currency : Punch::Currency, lines : Array(Line), created_at : Time do
    def send(number : Invoices::Number, at : Time) : Sent | NoLines
      return NoLines.new if lines.empty?

      Sent.new(id, customer_id, currency, lines, created_at, number: number, sent_at: at, due_at: at + Invoices::PAYMENT_TERM)
    end
  end

  record Sent, ..., number : Invoices::Number, sent_at : Time, due_at : Time

  alias Any = Draft | Sent
end
```

A store turns rows into the right state type and a model back into columns, with the generated queries. Load, change, and save happen inside the Command's one write transaction, so no version columns or row locks are needed:

```crystal
def call(input : Input, db : Punch::Writer) : Detail | NotFound | AlreadySent | NoLines
  case invoice = Store.load(db, input.invoice_id)
  in Nil           then NotFound.new
  in Invoice::Sent then AlreadySent.new(invoice)
  in Invoice::Draft
    now = Time.utc

    case sent = invoice.send(Store.next_number(db), now)
    in Invoice::NoLines then NoLines.new
    in Invoice::Sent
      Store.save(db, sent)
      Detail.new(sent, now)
    end
  end
end
```

Adding a state breaks every `case … in` that has to handle it; that is the point of the tier.

- **Store:** a module or class whose name ends in `Store`. It is the one place besides operations that takes database handles (`Punch/ModelDatabase`).
- **Operations branch on types, not on statuses.** `Punch/StatusComparison` reports `invoice.status == …`, `row.status.sent?`, `case row.status`, and the like inside a `Command` or `Query`. Converting a stored status to a state belongs in the store; rendering one into a result is fine.

## Lint rules

All apply to code under `app/`; generated files are skipped, except that `Punch/NamespaceFile` looks at `queries.gen.cr` to find entities.

| Rule | Reports |
|---|---|
| `Punch/NamespaceFile` | An entity directory (one with `queries.sql`) without the outline file beside it; an outline that is not one documented module named after the directory, holding at most documented constants with plain values; a doc comment on the entity's module in another file |
| `Punch/RecordFile` | A `struct …::Record` outside the `record.cr` named after it |
| `Punch/ModelDatabase` | `Punch::Reader`, `Punch::Writer`, `Punch::Database`, or `Punch::Databases` outside an operation (a `Command` or `Query` subclass) or a store (a type named `…Store`) |
| `Punch/StatusComparison` | A status comparison inside an operation: `==`, `!=`, `===`, `in?`, `includes?`, a predicate such as `sent?`, or `case` on `x.status`. `StatusMethods` in `.ameba.yml` names other methods to treat as a status |

`Punch/StatusComparison` cannot see types, so it also reports a status check on an entity that has no state types. That check in an operation is the signal to move the entity to tier 2. When it is not worth it yet, disable the rule on that line (`# ameba:disable Punch/StatusComparison`), which leaves a mark to come back to.

## Testing

Records and rows are plain structs with keyword constructors, so model specs need no database:

```crystal
row = Billing::Invoices::Queries::Page::Row.new(id, "sent", number, eur, customer_id, name, 0_i64, sent_at, due_at)
row.overdue?(now).should eq(sent.overdue?(now))
```

Endpoint specs then check the same field through the API (`reference/spec/billing/invoices_api_spec.cr`).

A store's spec checks "save, then load, returns the same model" in every state, because a field the mapper forgets is a quiet bug:

```crystal
Punch::Spec.db.write do |db|
  Punch::Spec.round_trip(draft, sent, covering: Billing::Invoices::Invoice::Any) do |invoice|
    Billing::Invoices::Store.save(db, invoice)
    Billing::Invoices::Store.load(db, invoice.id)
  end
end
```

It fails when a model comes back different, naming each field (`Round trip of Billing::Invoices::Invoice::Sent changed due_at: saved …, loaded …`), when the load returns `nil` or another state, and when a state of `covering` has no model. Give each field a value other than its default, or a forgotten one comes back equal by chance. Without `covering:` it checks only the models given.

## For review

A change to a model file, a `record.cr` or a behaviour module, is a change to a business rule. Those are the diffs to read most closely.

## Not yet

- The `-- include` header is an open decision; it may give way to reopening the row in a hand-written file.

