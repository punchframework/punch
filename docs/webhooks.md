# Inbound webhooks

Learn it in: [Inbound Webhooks](guides/inbound-webhooks.md).

Other systems tell an app what happened by posting to it: a payment succeeded, a mail bounced. Punch receives such deliveries first and processes them later: the endpoint stores the request and answers at once, and a job processes it through the outbox. A delivery that arrives twice is processed once; one with a bad signature is refused.

## A provider

A provider is a struct that subclasses `Punch::Webhook::Inbound`, named by `@[Punch::Webhook::Provider]`:

```crystal
@[Punch::Webhook::Provider("payments")]
struct Billing::Payments::Provider < Punch::Webhook::Inbound
  # The secrets deliveries are signed with; nil without any, then the
  # endpoint answers 404.
  def verifier : Punch::Webhook::Verifier?
    secrets = Invoicing::Credentials.current.payments.webhook_secrets || return
    Punch::Webhook::HMAC.new(secrets)
  end

  # The body as one of the provider's typed events.
  def parse(request : Punch::RawRequest) : Succeeded | Punch::Webhook::Ignored | Punch::Webhook::Unprocessable
    case envelope = Envelope.from_json(request.body)
    in Punch::Rejection then Punch::Webhook::Unprocessable.new("not an event")
    in Envelope
      return Punch::Webhook::Ignored.new(envelope.event) unless envelope.event == "payment.succeeded"

      case succeeded = Succeeded.from_json(request.body)
      in Punch::Rejection then Punch::Webhook::Unprocessable.new("payment.succeeded without a valid payment")
      in Succeeded        then succeeded
      end
    end
  end

  # One `process` per event type; it writes like a Command.
  def process(event : Succeeded, db : Punch::Writer, events : Punch::Events(InvoicePaid)) : Punch::Webhook::Outcome
    # load, change, save, publish
    Punch::Webhook::Processed.new
  end
end
```

The annotation takes the name, which is the endpoint (`POST /webhooks/payments`) and the stored `provider`, and optionally:

| Option | Default | |
|---|---|---|
| `verify:` | `:edge` | `:edge` checks the signature before storing and answers 401 to a bad one. `:deferred` stores first and checks in the job, against the time the request arrived, for providers that must get a 2xx quickly. `:none` checks nothing and needs no verifier: its deliveries are stored as `verified` and processed unverified; `punch webhooks` and `punch check` list such providers |
| `body_limit:` | 256 KiB | Bytes; larger bodies get 413 |
| `rate_limit:` | 600 | Requests per minute and client address |

## The endpoint

Punch adds the provider's `Receive` Command (`Billing::Payments::Provider::Receive.path`). It is public, left out of `openapi.json`, rate-limited by client address, and not subject to the cross-site check in practice: providers' servers send no `Origin` or `Sec-Fetch-Site`, and the endpoint carries no ambient credentials. The body is not parsed as JSON there; it is stored as received, whatever its type.

| Delivery | Answer |
|---|---|
| New | 204; stored, and its processing enqueued through the outbox in the same transaction |
| Same key, same body | 204; nothing stored |
| Same key, other body | 409 `idempotency_key_reused` |
| Bad, missing, or old signature (`verify: :edge`) | 401 `invalid_signature`; nothing stored |
| No verifier (no secret in the credentials) | 404 `not_found` |

**The key** is the provider's idempotency key: the Standard Webhooks `webhook-id` unless `idempotency_key(request)` says otherwise (a header, a field of the payload). It must be part of what the signature covers, or a captured delivery can be replayed under a new key; and repeats are recognized only while the first is kept (`PUNCH_WEBHOOK_RETENTION_DAYS`). Without one it is the SHA-256 of the body, so an identical body counts as a repeat. Under `:deferred` the stored key also holds the body's hash: an unverified delivery must not claim the key before the genuine one arrives. At most 1,000 deliveries of a provider wait unverified (`MAX_UNVERIFIED`); beyond that `:deferred` answers 503 and the provider retries later, since anyone can post one. A unique index on provider and key decides, and the stored body's hash tells a repeat from a conflict.

**What is stored:** the body as bytes, its hash, and the headers the verifier reads plus `headers` (by default `content-type`).

## Verification

`Punch::Webhook::HMAC` verifies the Standard Webhooks scheme (`Punch::Webhook::Signature`, `webhook-id`, `webhook-timestamp`, `webhook-signature`): HMAC-SHA256, constant-time, five minutes of tolerance against replays, and any of several secrets, so a provider's rotation goes through with the old and the new secret listed. Header names and the tolerance can be changed (`HMAC.new(secrets, tolerance: 1.minute, signature_header: "x-signature")`). A provider with another scheme writes a `Punch::Webhook::Verifier` (`headers`, `verify(request, now)`). A secret must have at least 16 bytes (`whsec_` secrets after decoding): `HMAC.new` refuses a shorter or broken one, since an empty key lets anyone sign. A timestamp must be plain digits. A verifier that raises rejects the delivery (`verifier_failed`).

## Processing

`Punch::Webhook::Process` is Punch's job, on the queue `webhooks`, at most four at a time per provider. It loads the invocation and moves it through its states, one type per state (a tier-2 model, `Punch::Webhook::Invocation`):

```text
Received ──verify──> Verified ──> Processed | Ignored | Discarded | Failed | Unprocessable
    └──────────────> Rejected
```

Only a `Verified` invocation reaches `parse` and `process`, so unverified data is never processed.

| `parse` or `process` returns | The invocation | The job |
|---|---|---|
| `Processed` | `processed`, in the transaction of the handler's writes | done |
| `Ignored` (from `parse`) | `ignored`, with the reason | done |
| `retry(reason, after:)` (a `Punch::Job::Retry`) | stays `verified`, attempt and reason recorded; the handler's writes roll back | retried with backoff |
| a retry on the last attempt, or an exception on the last attempt | `failed` | failed |
| An exception | stays `verified`, recorded; rolled back | retried, recorded as a bug |
| `discard(reason)` (a `Punch::Webhook::Discarded`, from `process`) | `discarded`, with the reason; the handler's writes roll back; no failure event | discarded with the reason |
| `Failed` | `failed` | discarded with the reason |
| `Unprocessable` (from either) | `unprocessable` | discarded with the reason |

An invocation that ends `failed` or `unprocessable` publishes `Punch::Webhook::ProcessingFailed` (provider, invocation, state, reason) and calls the provider's `on_failure(invocation, db)`, in the transaction that records it. Subscribe to the event to alert someone.

`process` takes the event, the writer, and optionally `events : Punch::Events(...)` and `jobs : Punch::Jobs(...)`, as a Command's `call` does; `punch events` lists the provider as the publisher. A job runs at least once: an invocation that is finished already is left alone, so processing twice does nothing the second time.

**Telemetry:** the request's wide event has `punch.webhook.provider`, `punch.webhook.invocation`, and `punch.webhook.outcome` (`received`, `duplicate`, `conflict`, `invalid_signature`); the job continues the request's trace and has the outcome (`processed`, `ignored`, `retry`, `failed`, `rejected`) and `punch.webhook.lag_ms` from receipt to the first attempt.

## Storage and retention

The table `punch_webhooks` lives in the app's migrations; `serve` refuses to start without it when the app has a provider:

Write it with `punch db:migration --punch webhooks` (the SQL is `Punch::Webhook::Invocations.sql`); `punch check` compares the table in `db/schema.sql` with what this Punch expects (step `punchtables`).

Raw bodies often hold personal data. `Punch::Webhook::Purge` removes processed, ignored, discarded, and rejected invocations after `PUNCH_WEBHOOK_RETENTION_DAYS` (30), every hour; failed and unprocessable ones stay until someone has looked at them.

## Inspecting

`punch webhooks` (`--json`) lists the providers with their endpoint and verification, and how many invocations each has per state. The ops console (`/_punch/webhooks`, `docs/ops.md`) lists invocations by provider and state, shows the stored request, and retries a failed, unprocessable, or rejected invocation or replays a processed or ignored one, through the outbox.

## Specs

```crystal
response = Punch::Spec.client.deliver_webhook(Payments::Provider::Receive.path, body, secret: SECRET)
response.status.should eq(HTTP::Status::NO_CONTENT)
-> { Punch::Spec.perform_jobs }.should publish(InvoicePaid, invoice_id: id)
Punch::Spec.webhooks.last.should be_a(Punch::Webhook::Invocation::Processed)
```

`deliver_webhook` signs by the Standard Webhooks scheme; `id:` sets the key, `at:` the time it was signed. `Punch::Spec.webhooks` returns the example's invocations in their states, oldest first.
