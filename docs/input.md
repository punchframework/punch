# Input

Learn it in: [Input and Domain Types](guides/input-and-domain-types.md), [Forms](guides/forms.md).

An operation's input is a struct that includes `Punch::Input`. Parsing it returns the struct, with every field typed, or a `Punch::Rejection` with every error found, up to the first 100.

```crystal
struct Input
  include Punch::Input

  @[Punch::PathParam]
  getter invoice_id : Invoices::ID

  getter recipient : Punch::Email
  getter note : String?               # optional
  getter copies : Int32 = 1           # optional, with a default
  getter? urgent : Bool = false
  getter lines : Array(Line) = [] of Line
end

Input.from_json(body, path_params)    # => Input | Punch::Rejection
Input.from_query(query, path_params)
Input.from_form(form, path_params)    # a browser's form body
```

The router calls these; application code rarely does.

## Three rules

1. Fields marked `@[Punch::PathParam]` come from the URL path. The others come from the JSON body (`from_json`, used for Commands), the query string (`from_query`, used for Queries and pages), or a form body (`from_form`, used for Commands whose form a page holds, `docs/views.md`). A path parameter is never read from the body or the query string.
2. A field is required unless its type is nilable or it has a default.
3. Every error is collected, with its path, into one rejection.

## Field types

| Type | JSON | Path and query string | Form body |
|---|---|---|---|
| `String` | string | as given | as given |
| `Bool` | `true`, `false` | `true`, `false` | same; a checkbox sends `true` or nothing |
| `Int32`, `Int64` | integer in range | digits, optional `-`, no leading zeros | same |
| `Float64` | number, finite | JSON number syntax | same |
| `Time` | RFC 3339 string with offset | same | same |
| An enum | snake_case member name: `amount_desc` | same | same |
| A domain primitive (`Punch::Primitive(T)`) | read as `T`, then `.parse` | same | same |
| A nested `Punch::Input` | object | bracketed names: `filter[status]` | bracketed names: `address[street]` |
| `Array` of any of these | array | repeated key: `ids=4&ids=5`; no arrays of inputs | repeated key; rows of inputs as `lines[0][description]` |

Any other type, a union other than `T?`, a flags enum, a nilable path parameter, or an array of inputs in a query string does not compile. The message names the field.

Two primitives are refused too, since a client must not name them: a `Punch::Upload::Key` could point at another user's file, and a `Punch::Upload::ScanState` could pass its own file as clean (`docs/uploads.md`). A `Punch::Upload::Ticket` is the field that takes a new upload.

## Strictness

- **Unknown fields are ignored** in JSON bodies and query strings, so clients can send more than an input declares and links can carry tracking parameters. The cost: a misspelled optional field is dropped without an error.
- **Repeated keys are rejected** (`duplicate_field`), because parsers disagree on which value wins. In a query string this applies to single-value fields; repeated keys are how arrays are sent.
- In JSON, `null` counts as absent for an optional field and as `required` for any other. An empty body counts as `{}`.
- In a query string and a form body, an empty value counts as absent, as HTML forms send it. So a checkbox needs a `Bool` with a default (`getter? urgent : Bool = false`): unchecked, it sends nothing.
- In a query string and a form body, a nested input whose fields are all empty counts as absent (its default applies), and a key without brackets (`filter=paid`) is ignored like any unknown one. In a form body, a row of an array of inputs whose fields are all empty is left out too: forms show empty rows to fill in. Rows are numbered from 0 without gaps (`invalid_index` otherwise), and an error names the row as the form did (`lines.2.quantity`), also when empty rows before it were left out.

## Rules across fields

Override `check`. It runs only once every field has parsed, also for nested inputs:

```crystal
def check(errors : Punch::Rejection::Collector) : Nil
  errors.add("ends_on", Punch::Invalid.new("before_start")) if ends_on < starts_on
  errors.add(Punch::Rejection::Path.new, Punch::Invalid.new("too_many_lines")) if lines.size > 100
end
```

## Building an input in code

An input may define its own `initialize`, for code that builds one rather than parsing it; a query's generated `Filter` does (`docs/queries.md`). Parsing still goes through `from_json`, `from_query`, and `from_form`, whose constructors Punch declares in the type itself so that yours does not hide them. `check` does not run for an input built this way.

```crystal
def initialize(*, @status : String? = nil, @unsent : Bool = false)
end
```

## Error codes

| Code | Meaning | Params |
|---|---|---|
| `required` | Absent, or `null` for a field that is not optional | |
| `duplicate_field` | The same key twice | |
| `malformed_json` | The body is not JSON | `line`, `column` |
| `expected_object`, `expected_array`, `expected_string`, `expected_integer`, `expected_number`, `expected_boolean` | Wrong JSON type, or a string that is not an integer, number, or boolean | |
| `out_of_range` | An integer outside its type, or a number that is not finite | `min`, `max` for integers |
| `invalid_date_time` | Not RFC 3339 | |
| `invalid_choice` | Not the name of an enum member | |
| `invalid_encoding` | Not UTF-8 | |
| `invalid_index` | Form rows not numbered 0, 1, 2, … | |

Domain primitives add their own codes (see `core-types.md`).

## Testing

Inputs have no keyword constructor: an input exists only by parsing. In specs, build one from plain values with `Punch::Spec.input`; it fails the example with every error if the values do not parse:

```crystal
input = Punch::Spec.input(Send::Input, {"invoice_id" => "42"}, recipient: "ann@example.org")
Send::Input.from_json(%({"recipient": "nope"})).should be_rejected("recipient", code: "invalid_email")
```
