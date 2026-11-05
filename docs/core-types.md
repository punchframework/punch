# Core types

Learn it in: [Input and Domain Types](guides/input-and-domain-types.md), [Results, Errors, and Status Codes](guides/results-errors-and-status-codes.md).

Parse at the boundary, trust inside. These types are what parsing produces.

## Results are unions

Punch has no `Result` type. A method that can fail in an expected way returns a union of its success type and one small struct per failure, and the caller handles every member with an exhaustive `case … in`:

```crystal
alias Output = Sent | NotFound | AlreadySent

case result = Send.new.call(input, db)
in Sent        then ...
in NotFound    then ...
in AlreadySent then ...
end
```

Expected failures are values. An exception is a bug.

## Invalid and Rejection

Parsing one value returns the value or a `Punch::Invalid`:

```crystal
Punch::Email.parse(raw)   # => Punch::Email | Punch::Invalid
```

An `Invalid` holds a snake_case `code` and `params`, such as `too_long` with `max: 254`. It holds no sentence: messages are rendered in the request's locale at the edge.

Parsing a whole input collects every failure into a `Punch::Rejection`: a list of `Rejection::FieldError`s, each with a path such as `["lines", 2, "amount"]`. The empty path means the input as a whole, for cross-field rules. `Punch::Input` builds rejections for you. By hand, use the collector:

```crystal
errors = Punch::Rejection::Collector.new
email = errors.check("email", Punch::Email.parse(raw_email))
name = errors.check("name", Punch::NonEmptyString.parse(raw_name))
errors.result { Signup.new(email.not_nil!, name.not_nil!) }   # => Signup | Punch::Rejection
```

## Domain primitives

A domain primitive is a value that exists only after it has been parsed. Include `Punch::Primitive(T)` and define `self.parse`:

```crystal
struct InvoiceNumber
  include Punch::Primitive(String)

  def self.parse(raw : String) : self | Punch::Invalid
    return Punch::Invalid.new("invalid_invoice_number") unless raw.matches?(/\AINV-\d{6}\z/)

    new(raw)
  end
end
```

The compiler enforces the rules: a primitive without `self.parse` does not compile, a public `initialize` does not compile, and `new` cannot be called from outside. Primitives compare and hash by value, and print and serialize to JSON as their value. A primitive with constraints can declare JSON Schema keywords in `self.json_schema` (`docs/json-schema.md`).

Provided:

| Type | Accepts | Codes |
|---|---|---|
| `Punch::NonEmptyString` | Text with a visible character; trimmed, NFC | `blank`, `invalid_characters`, `invalid_encoding` |
| `Punch::Slug` | `annual-report-2026`: lowercase ASCII and digits, single hyphens, at most 100 characters; checked, not converted | `blank`, `too_long`, `invalid_slug` |
| `Punch::Email` | `local@domain`, international forms included; lowercased. No quoted local parts, IP literals, or single-label domains | `blank`, `too_long`, `invalid_email`, `invalid_characters`, `invalid_encoding` |
| `Punch::Upload::Filename` | The name of a file from a client: cleaned, at most 255 bytes (`docs/uploads.md`) | `invalid_filename` |
| `Punch::Upload::Ticket` | `upl_` and 32 Base32 characters, naming one upload until it is claimed | `invalid_upload` |

All text primitives reject invalid UTF-8 and control characters other than tab and line breaks, strip surrounding whitespace, and normalize to NFC, so `Café` typed two ways is one value.

### Money

`Punch::Money` is an amount in the minor unit of its currency: cents for `EUR`, yen for `JPY`. It is an integer everywhere, so sums never round:

| | |
|---|---|
| Wire | a JSON integer: `1250` is 12.50 EUR |
| Database | an `INTEGER` column |
| Range | ±(2^53 − 1), the integers a JavaScript client reads exactly; `out_of_range` outside |
| Currency | travels once, beside the amounts or on the parent object, as `Punch::Currency` (`EUR`; three uppercase letters, `invalid_currency`) |

```crystal
total = lines.sum(Punch::Money.zero) { |line| line.unit_price * line.quantity.value }
```

`+`, `-`, and `*` by an integer raise `OverflowError` beyond the range: bound what feeds a sum (line counts, quantities, unit prices) so it cannot, as the reference app does. Money of two currencies is not added by the type; keep one currency per document. `currency.minor_unit` gives a currency's decimals (ISO 4217: `JPY` none, `KWD` three, most two); `locale.money(amount, currency)` writes an amount for people (`docs/translations.md`).

## Typed IDs

One ID type per kind of record, so a customer ID cannot go where an invoice ID is expected:

```crystal
module Billing::Invoices
  struct ID < Punch::TypedID
  end
end

Billing::Invoices::ID.parse("42")   # => Billing::Invoices::ID | Punch::Invalid
```

A typed ID is a positive `Int64`, the SQLite rowid. From strings it accepts only the canonical decimal form: no sign, leading zeros, or whitespace. IDs of one type compare and sort by value. IDs of two different types are never equal; the compiler cannot stop that comparison because it has to allow comparisons between unions.

### Public IDs

A rowid in a URL or an answer counts records: `/billing/invoices/412` says how many invoices exist, and two of them a week apart say how many were written in between. `public_id` gives an ID type a public form instead:

```crystal
module Billing::Invoices
  struct ID < Punch::TypedID
    public_id "inv"
  end
end

id.to_s     # => "inv_gLW26G63FZp"
id.value    # => 42, the rowid
Billing::Invoices::ID.parse("inv_gLW26G63FZp") # => the same ID
Billing::Invoices::ID.parse("42")              # => Punch::Invalid invalid_id
```

The public form is the prefix, `_`, and 11 base58 characters: the rowid through a keyed permutation of 64 bits (an 8-round Feistel network with SipHash-2-4 rounds). Nothing is stored and nothing is looked up. Neighbouring rowids give unrelated texts, and two types with the same rowid give unrelated texts too. Without the key, the text neither counts records nor tells the next one.

| Where | Form |
|---|---|
| `to_s`, `to_json`, `parse(String)`, paths, query strings, forms, JSON bodies and answers, `Punch.dom_id`, the JSON Schema and OpenAPI document | public: `"inv_gLW26G63FZp"`; a number is refused |
| `value`, `parse(Int)`, `Punch::Stored`, generated queries, foreign keys | the rowid |
| What the app stores for itself (job payloads, step cursors, cached values; `Punch::Stored.json`) | the rowid, so a payload does not depend on the key and a binary from before the change reads it |
| A page cursor over a public ID (`docs/queries.md`) | sealed: encrypted under a key derived from the public-ID key |

- **The prefix** is 2 to 8 lowercase letters, one per ID type; two types with one prefix do not compile.
- **The key** is `public_id_key` in the app's credentials (`docs/keys.md`). It is not part of the key ring and never rotates: a new key gives every record a new public ID, and the old ones stop resolving. An app with public IDs and no key does not boot.
- **The table** needs `INTEGER PRIMARY KEY AUTOINCREMENT`. Without it SQLite gives the rowid of a deleted last row to the next row, so an old link would lead to a new record; the generated `Table` module does not compile then (`docs/migrations.md`). `punch generate` writes new tables that way.
- **Turning it on changes the API:** every path, body and answer with the ID goes from a number to a string. The `openapi` and `payloads` checks report it.

A public ID hides counts and guesses. It is not access control: whoever holds the key reads the rowid, and a policy still decides who sees a record (`docs/authorization.md`). The IDs of types without `public_id`, such as users' and organizations', still count their records. Opt those in as well where that matters. Live pages (`docs/views.md`) still count: their position, `<boot>-<sequence>`, numbers every committed event of the process, whichever organization it belongs to.

## Secret(T)

`Punch::Secret(T)` wraps a value that must not leak: credentials, tokens, decrypted columns.

- `to_s`, `inspect`, and interpolation print `[REDACTED]`, so the value stays out of logs and error reports.
- `to_json`, `to_yaml`, and use as a `Hash` key do not compile.
- `unwrap` is the only way to the value. Call it at the point of use.
- `map` derives a new secret. `==` compares `String` and `Bytes` in constant time.

The wrapper prevents accidents, not attacks on the process: the value is not wiped from memory, and an unwrapped value is an ordinary value.

## Testing

`require "punch/spec"` adds two matchers:

```crystal
Punch::Slug.parse("A B").should be_invalid("invalid_slug")
Punch::Slug.parse("a" * 101).should be_invalid("too_long", max: 100)
rejection.should be_rejected("lines", 0, "amount", code: "negative")
rejection.should be_rejected(code: "ends_before_start")   # the input as a whole
```
