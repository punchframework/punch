# JSON endpoints and OpenAPI

Learn it in: [Building a JSON API](guides/building-a-json-api.md).

Every operation is a JSON endpoint. Its input comes from the path, the query string, or a JSON body; its result goes out as JSON or as Problem Details (RFC 9457); and the OpenAPI 3.2 document of all of them is a committed file, `openapi.json`, derived from the code.

## Results and statuses

`call` returns a union of result types. Each type's status comes from `@[Punch::Status(code)]`, 200 by default. A result of several types, though, states the status of every member (a success too: `@[Punch::Status(200)]`): a failure that forgot its annotation would answer 200, commit the Command's writes, and show as a success in `openapi.json`, so the build refuses it, at the operation's `call`. Nil, `Punch::Rejection`, violations, `Punch::Auth::Unauthenticated`, and `Punch::Policy::Refused` have their statuses and need nothing; an operation that returns one type of its own (and perhaps those) keeps the default.

```crystal
@[Punch::Status(201)]
struct Created
  include JSON::Serializable

  getter id : Invoices::ID
end

@[Punch::Status(409)]
struct AlreadySent
  include JSON::Serializable

  getter sent_at : Time
end

def call(input : Input, db : Punch::Writer) : Created | NotFound | AlreadySent
```

| Result | Response |
|---|---|
| `nil` | 204, no body |
| a type below 400 | its JSON (`to_json`), `application/json` |
| a type from 400 on | Problem Details, `application/problem+json` |

A status outside 200–599 does not compile.

A failure type includes `Punch::Problem`: it adds `JSON::Serializable` and, for a failure with no fields, the empty constructor, and it requires `@[Punch::Status(400..599)]` (a status from 400 to 599; the build refuses it otherwise). So the failure cannot be a 200 by omission:

```crystal
@[Punch::Status(409)]
struct AlreadySent
  include Punch::Problem

  getter sent_at : Time

  def initialize(@sent_at : Time)
  end
end

@[Punch::Status(404)]
struct NotFound
  include Punch::Problem   # no fields: `NotFound.new` works
end
```

## Problem Details

Every error response has the same shape, whether it comes from a result, a rejected input, or the framework:

```json
{"type": "about:blank", "title": "Conflict", "status": 409, "code": "already_sent",
 "request_id": "01J…", "sent_at": "2026-10-08T09:30:00Z"}
```

- `type` is `about:blank`, so `title` is the status phrase.
- `code` names the problem in snake_case: the result type's name (`AlreadySent` → `already_sent`), `invalid_input` for a rejected input, and the status for framework problems (`not_found`, `method_not_allowed`, `payload_too_large`, `unsupported_media_type`, `internal_server_error`).
- A result type's JSON fields become extension members. A field named like a Problem Details member (`type`, `title`, `status`, `code`, `detail`, `instance`, `request_id`, `errors`) does not compile.
- Codes, never sentences: messages are rendered from codes at the edge, in the reader's language.

A rejected input is 422 with every error:

```json
{"type": "about:blank", "title": "Unprocessable Entity", "status": 422, "code": "invalid_input",
 "request_id": "01J…", "errors": [{"path": ["lines", 2, "amount"], "code": "negative", "params": {}}]}
```

## The OpenAPI document

`punch openapi` writes `openapi.json` for the app in the current directory:

1. It builds the first target of `shard.yml` with `-Dpunch_openapi`. Only this build compiles the derivation; normal builds never do (`docs/json-schema.md`, Cost).
2. It runs that binary's `openapi:derive`, which derives the document from the operations: paths and methods from the route table, `operationId` from the operation's name and a tag from its slice (`billing`), parameters and request bodies from the inputs, responses from **the declared return type of `call`**. A body that today returns fewer types does not shrink the contract; an undeclared return type falls back to the inferred one.
3. It runs `crystal docs --format json` and adds the doc comments: a type's to its schema, a getter's to its property, an operation's to the operation (its first sentence as `summary`).
4. It writes the document, sorted, so diffs stay small.

| Part | From |
|---|---|
| Path parameters | `@[Punch::PathParam]` fields, always required |
| Query parameters (Queries) | the other input fields; required unless nilable or defaulted; never `null`. A nested input (a list's `filter`) is one parameter with `style: deepObject`, `explode: true`: `filter[status]=paid` |
| Request body (Commands) | the input's schema, required when a field is |
| Responses | one per status of the result types, alternatives as `oneOf`; problems as `Punch.Problem` plus their `code` and fields |
| 422 | `Punch.ValidationProblem`, for every operation with input fields |
| 401 | `unauthenticated`, for operations that take the actor (`docs/auth.md`) |
| 403 | `cross_origin_request` on every Command; `forbidden` on operations with a policy (`docs/authorization.md`) |
| 404 | `not_found` on operations with a policy, beside the operation's own |
| 429, 503 | rate-limited operations (`docs/rate-limits.md`); Commands that hash passwords (`docs/auth.md`) |
| `default` | `Punch.Problem`: 404, 405, 413, 415, 500 |
| Schemas | `Punch::JSONSchema`, under `components/schemas` |

The app serves the committed file at `GET /openapi.json`:

```crystal
router = Punch::Routing::Router.new(database, openapi: Punch.openapi_document)
```

`Punch.openapi_document` embeds `openapi.json` at compile time; it is `nil` until the file exists.

## Commands

| Command | Does |
|---|---|
| `punch openapi` | Writes `openapi.json`; `--check` writes nothing and fails with `stale_openapi` when the committed file differs |
| `punch openapi:diff OLD NEW` | Lists breaking changes and fails on them, unless the new `info.version` (from `shard.yml`) raises the major version, or the minor one before 1.0 |

Both are in the standalone `punch` binary. Breaking means a client that was correct against the old document fails against the new one:

- an operation or a success response is gone;
- a request needs more: a new required parameter or property, a body that became required, a type or enum value no longer accepted;
- a response promises less: a property removed or no longer always present, a new type, a new enum value.

Adding operations, optional inputs, response properties, and accepted values is fine. Schemas are compared through their `$ref`s, so renaming a component is not a change.

In CI, against the main branch:

```sh
punch openapi --check
git show origin/main:openapi.json > tmp/openapi.main.json
punch openapi:diff tmp/openapi.main.json openapi.json
```

## Cost

The `-Dpunch_openapi` build only derives the document and never serves a request, so its route table points every route at a stub handler: endpoints (parsing, calling, rendering, tracing) are not compiled in it. At 400 operations it needs 5.1 s and 1.18 GB of the 2.5 GB compiler budget (with endpoints: 11.2 s, 1.96 GB; a normal build with a server and the CLI: 2.30 GB). The derivation is written so that only the type-dependent part is compiled per operation; anything added to it per operation must be measured first.

## A database row is not a response

A generated `Record` or query `Row` has no JSON form: returning one in a result, or putting one into a result struct, does not compile (`Ledger::Customers::Record is a database row, not a response`). Return a result struct with the fields to show, built from the row (`Customer.new(record)` in the reference app), so the wire shape is declared and appears in `openapi.json`. The error names the row type; its location is where the result is first serialized, so look for a field of that type in your result.
