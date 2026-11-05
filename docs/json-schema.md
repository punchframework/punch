# JSON Schema

Learn it in: [Building a JSON API](guides/building-a-json-api.md).

Punch derives JSON Schema (draft 2020-12) from Crystal types, once, in `Punch::JSONSchema`. The OpenAPI document and the job payload lock are built on it; forms take their lengths, ranges, and formats from it, and action blocks describe what the forms write, so a type is described the same way everywhere.

```crystal
Punch::JSONSchema.of(Billing::Invoices::Send::Input)
# {"$schema": "https://json-schema.org/draft/2020-12/schema",
#  "$ref": "#/$defs/Billing.Invoices.Send.Input",
#  "$defs": {"Billing.Invoices.Send.Input": {"type": "object", "properties": {…}, "required": […]}}}
```

## What a schema says

A schema describes exactly what Punch reads and writes; specs check it against the parser.

**Inputs** (`Punch::Input`) are objects of their body or query fields:

- A field is **required** unless it is nilable or has a default, exactly as the parser decides.
- Only **nilable** fields accept `null`. A field with a default is optional, but `null` is still rejected.
- **Defaults** that are literals or enum members appear as `default`.
- **Path parameters** are left out of the object. `JSONSchema.fields(Input, registry)` lists every field, path parameters marked, for OpenAPI parameters and form controls.
- There is no `additionalProperties: false`: unknown fields are ignored.

**Outputs** (types that include `JSON::Serializable`) are objects of what `to_json` writes: `@[JSON::Field(key:)]` renames, `ignore` leaves out, and `emit_null` makes a nilable field required. A field with a `converter` does not compile, because its JSON cannot be known.

**Stored payloads** (job and event payloads) are derived with `Registry.new(payloads: true)`: an object's `required` lists what `JSON::Serializable` needs to read it, fields that are neither nilable nor defaulted, rather than what `to_json` always writes. The payload lock compares both sides of a deploy from that (docs/jobs.md).

**Values:**

| Type | Schema |
|---|---|
| `String`, `Bool` | `string`, `boolean` |
| `Int32`, `Int64`, `Float64` | `integer` with `int32` / `int64`, `number` with `double` |
| `Time` | `string`, `date-time` (RFC 3339) |
| enum | `string` with `enum` of the snake_case member names, as inputs parse and `to_json` writes them. Flags enums do not compile |
| domain primitive | the stored type's schema plus the primitive's keywords (below) |
| `Array(T)`, `Hash(String, T)` | `array` with `items`, `object` with `additionalProperties` |
| `T?` | `null` added to `type`, or `anyOf` with `{"type": "null"}` for a reference |
| other unions | `anyOf` |

Anything else does not compile, with a message listing what is supported.

## Domain primitives

A primitive is described by its stored type plus keywords it declares:

```crystal
struct InvoiceNumber
  include Punch::Primitive(String)

  def self.json_schema
    {pattern: "^INV-[0-9]{6}$"}
  end
end
```

| Primitive | Keywords |
|---|---|
| `Punch::Email` | `format: idn-email`, `maxLength: 254` |
| `Punch::Slug` | `pattern`, `minLength: 1`, `maxLength: 100` |
| `Punch::NonEmptyString` | `pattern: \S` |
| typed IDs | `minimum: 1` |

`json_schema` restates what `parse` checks, and nothing makes the two agree by itself. Give every primitive that declares one a spec with `Punch::Spec.schema_agrees`:

```crystal
Punch::Spec.schema_agrees(Billing::Invoices::Number,
  valid: ["INV-000001", "INV-1000000"],
  invalid: ["", "INV-00001", "inv-000001", "INV-000001 "])
Punch::Spec.schema_agrees(Billing::Invoices::Quantity, valid: [1_i64, 10_000_i64], invalid: [0_i64, 10_001_i64])
```

It runs each sample through `parse` and through the type's schema (the validator the client's OpenAPI check uses) and fails, listing every sample the two answer differently. Samples are raw values of the stored type; put in the boundaries. The validator reads `pattern` as a Crystal (PCRE) regex, where `$` also matches before a final newline, unlike ECMAScript, so do not use a trailing-newline sample.

Primitives serialize to JSON as their value, so an `Email` in a response is a string and a typed ID a number.

## Names and the registry

Objects and enums are defined once and referenced with `$ref`; everything else is inline. A `Registry` collects the definitions for one document:

```crystal
registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
registry.schema(Send::Input)   # => {"$ref": "#/components/schemas/Billing.Invoices.Send.Input"}
registry.definitions           # sorted by name, for stable committed files
registry.type_names            # schema name => Crystal type name
```

- Names come from the Crystal name: `::` becomes `.`, anything outside `A-Z a-z 0-9 . _ -` becomes `_`. Two types that end up with one name raise.
- Recursive types work: a type is named before its fields are derived.
- A registry is not shared between threads; use one per document.

## Cost

Derivation runs in one small method per type and only for types that something derives. A build that never calls it pays nothing. Deriving every input and result of the benchmark app adds 0.3 s to a cold build and 0.4 s to a warm rebuild at 200 operations. At 400 operations it adds 2.0 s, 1.1 s, and 120 MB, which took the benchmark build without a server to 1.94 GB (budget then 2 GB, now 2.5 GB measured as a real app). That is why the OpenAPI document is derived in a separate build by `punch openapi`, not in every build.

## Not here

- **Descriptions.** Macros see doc comments only under `crystal docs`. `punch openapi` reads them from `crystal docs --format json`, which has the doc of each type and getter, and adds them through `Registry#type_names` and `Registry#field_names` (`docs/openapi.md`).
- **Inputs of one of several shapes** (`oneOf` with a discriminator).
