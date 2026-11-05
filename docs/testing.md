# Testing with `punch/spec`

Learn it in: [Testing Punch Applications](guides/testing-punch-applications.md).

Specs use Crystal's own `Spec`. `require "punch/spec"` in `spec/spec_helper.cr` adds helpers and matchers; the runner stays `crystal spec`, with its tags, focus, and random order.

```crystal
# spec/spec_helper.cr
require "punch/spec"
require "../src/invoicing"
```

Most specs go through `Punch::Spec.client` ("Endpoint specs" below): a request runs the policy, opens the transaction, and makes every handle `call` asks for, as in production, and the answer is checked against `openapi.json`. The reference app's specs all work that way. Call an operation directly when a rule needs no request; then build what its `call` takes with the helpers below.

## A fresh database per example

`Punch::Spec.db` is this example's database: in memory, with `db/schema.sql` loaded on first use, closed after the example. Every example starts from the same state without transaction tricks, so the code under test can commit, fail, and open its own transactions.

```crystal
it "sends a draft" do
  id = Punch::Spec.db.write { |db| Billing::Invoices::Table.insert(db, draft).id }
  input = Punch::Spec.input(Billing::Invoices::Send::Input, {"invoice_id" => id.to_s})
  result = Punch::Spec.db.write do |db|
    send = Billing::Invoices::Send
    grant = Punch::Spec.grant(send, actor, db, invoice_id: id) # actor: the app's actor, as the router loads it
    send.new.call(input, db, actor, grant, Punch::Spec.events(send, db), Punch::Spec.jobs(send, db))
  end
  result.should be_a(Billing::Invoices::Detail)
end
```

- The schema is `db/schema.sql` relative to where specs run, the app's root. Set `Punch::Spec.schema = "other.sql"` in the spec helper for another file, or `nil` for an empty database.
- Opening one costs about 0.5 ms with a 300-statement schema, so there is no template or rollback scheme to maintain.
- `Punch::Spec.database(file: true) { |db| … }` is a WAL database in a temporary directory, for code that depends on a second connection or process.

## Endpoint specs

`Punch::Spec.client` sends requests to the app in process: the router over `Punch::Spec.db`, through `HTTP::Server#process`, the same code a socket connection runs (security headers, request ID, multipart refusal, 500 on an exception), without the socket.

```crystal
it "answers 409 when sending twice" do
  client = Punch::Spec.client
  id = client.post(Billing::Invoices::Create.path, json: {number: "inv-1"}).json["id"].as_i64
  client.post(Billing::Invoices::Send.path(invoice_id: Billing::Invoices::ID.parse(id).as(Billing::Invoices::ID)))
  response = client.post(Billing::Invoices::Send.path(invoice_id: Billing::Invoices::ID.parse(id).as(Billing::Invoices::ID)))
  response.status.should eq(HTTP::Status::CONFLICT)
  response.json["code"].should eq("already_sent")
  response.trace.should have_span("Billing::Invoices::Queries.mark_sent")
end
```

**An exception in an operation fails the example with it.** The server answers an unhandled exception with a 500 problem, and a client that returned only that would hide the cause. So the client raises `Punch::Spec::ServerError` instead: its message is the request line and the exception's class and message (`POST /billing/invoices/inv_88EQGATEh1K/send raised KeyError: no such note`), and the original exception is its `cause`, printed with its backtrace. A spec that tests the 500 itself opts out per client, `Punch::Spec.client(raise_errors: false)` (or `client.raise_errors = false`); the exception is then `response.exception`, and the response is the 500 page.

```crystal
response = Punch::Spec.client(raise_errors: false).post(Billing::Invoices::Send.path(invoice_id: id))
response.status.should eq(HTTP::Status::INTERNAL_SERVER_ERROR)
response.exception.try(&.message).should eq("numbering broke")
```

| | |
|---|---|
| `get`, `head` | `(path, query: {page: 2}, headers: HTTP::Headers{…})` |
| `post`, `put`, `patch`, `delete` | also `json:` (any value with `to_json`; sets `Content-Type`) or `body:` (text as it is) |
| `request(method, path, …)` | any method |
| `Response` | `status`, `headers`, `body`, `json`, `content_type`, and `trace`: every span of the request (`trace?` is `nil` for `/up`, which is not traced) |

Build paths with `Operation.path(...)`, as the app does. `Punch::Spec::Client.new(handler, openapi: …, config: …)` takes any handler or router, for framework specs.

## The contract check

With an OpenAPI document, every response in an endpoint spec is checked against it: the contract test for free. The document is the app's committed `openapi.json`, embedded when the specs compile (`Punch::Spec.openapi`).

For the operation the request reached:

- the status must be documented, or covered by `default`;
- a response without documented content must have no body;
- `Content-Type` must be one the document names for that status;
- the body must match the schema.

A path outside the document is not checked, except that a problem must still be a `Punch.Problem`. A violation fails the example at the line of the request:

```
GET /billing/invoices/inv_5WKdaPEwGRs answered 200, which breaks the OpenAPI document:
  body (root): "due_on" is missing (required)
If the code is right, the document is stale: run 'punch openapi'.
```

Requests are not checked: specs send invalid input on purpose.

## JSON Schema

`value.should match_schema(schema, root: document)` checks a `JSON::Any` against a schema and lists every violation with its JSON Pointer. `Punch::JSONSchema.validate(value, schema, root)` returns them as `Violation`s. It knows what `Punch::JSONSchema` emits (`type`, `enum`, `const`, object and array keywords, string and number bounds, `pattern`, `allOf`, `anyOf`, `oneOf`, `not`, local `$ref`) and checks the formats `date-time`, `int32`, and `int64`; other formats are annotations. Only specs compile it.

A primitive's `json_schema` restates its `parse`, so each primitive that declares one gets `Punch::Spec.schema_agrees(Type, valid: [...], invalid: [...])`: it runs every raw sample through `parse` and through the type's schema, and fails listing each sample the two answer differently (`docs/json-schema.md`). Put the boundaries in the samples.

## Other helpers

| Helper | |
|---|---|
| `Punch::Spec.input(Type, path_params, **fields)` | An input built as a request would; fails the example with every error if it does not parse (`docs/input.md`) |
| `be_invalid(code, **params)`, `be_rejected(*path, code:)` | Parse failures (`docs/core-types.md`) |
| `Punch::Spec.trace { … }`, `have_span(name, **attributes)` | Spans (`docs/tracing.md`) |
| `Punch::Spec.eventually(timeout) { … }` | Retries an expectation, for effects after a response |
| `client.visit(href)`, `have_element(css, text:, count:)`, `Punch::Spec.render(component)` | Pages and components (`docs/views.md`); `render(component, authorizer: Punch::Policy::Authorizer.new(actor, reader))` asks the policies of forms and links (`docs/authorization.md`) |
| `Punch::Spec.grant(Command, actor, db, **path_params)` | The grant from the Command's policy, for calling it directly; raises when the policy refuses (`docs/authorization.md`) |
| `client.submit(Command.action(...), {field: value})`, `client.submit(action, form: {"field" => "raw"})` | A form as a browser sends it; the answer is not checked against `openapi.json` (`docs/views.md`) |
| `redirect_to(href)`, `have_field_error(name, code)` | A form's `303`, and a field marked invalid with that error (its `data-code`, in any language) |
| `Punch::Spec.round_trip(*models, covering: Union) { … }` | Save, then load, returns the same model, in every state; names each field that came back different (`docs/models.md`) |
| `->{ … }.should publish(Event, field: value, times: n)` | The block committed such events (`docs/events.md`); `should_not` for none. Fields are compared with `==`; a field the event does not have does not compile |
| `->{ … }.should enqueue(Job, field: value, at: time, times: n)` | After the block, the queue holds such new waiting jobs, through the outbox or directly (`docs/jobs.md`); `at:` to the millisecond |
| `Punch::Spec.published(Event) { … }`, `Punch::Spec.enqueued(Job)`, `Punch::Spec.perform_jobs` | The events themselves, the waiting jobs, running due jobs (`docs/events.md`, `docs/jobs.md`) |
| `client.deliver_webhook(path, body, secret:, id:, at:, headers:)` | A `POST` signed as a provider signs it, by the Standard Webhooks scheme (`webhook-id`, `webhook-timestamp`, `webhook-signature`; `Punch::Webhook::Signature`). A wrong `secret:`, an old `at:`, or a changed header tests the refusals |
| `Punch::Spec.uploads`, `Punch::Spec.upload(grant, bytes, db)` | Uploads kept in a temporary directory, and a file sent and checked as a browser does (`docs/uploads.md`) |
| `Punch::Spec.ops`, `Punch::Spec.clock` | This example's `ops.db` (`docs/ops.md`), and the clock that moves only when told |

`client.language = "de"` sends `Accept-Language` with every request of that client, so a spec sees the app in that language (`docs/translations.md`).

## The app's clock

`clock = Punch::Spec.clock(Time.utc(2026, 3, 1))` stops `Time.utc` and `Time.local` for the whole process until the example ends, and returns a clock that moves: `clock.advance(40.days)`, `clock.now = ...`. So a spec makes an invoice overdue by sending it earlier, not by rewriting its row. Moving it moves everything that reads the time: sessions, jobs, caches, and rate limits. Move it forward: a rate limit that already counted a request sees that request in the future after a move back.
