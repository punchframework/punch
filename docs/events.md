# Domain events

Learn it in: [Domain Events](guides/domain-events.md).

Side effects announced, not buried. A Command publishes typed events, and other code reacts to them in subscribers. The compiler knows every publisher and every subscriber, and `punch events` prints the whole graph. Events belong to the Command's transaction, so nothing is delivered after commit if the Command fails.

```crystal
module Billing
  record InvoiceSent,
    invoice_id : Invoices::ID,
    customer_id : Customers::ID do
    include Punch::Event
  end

  module Invoices
    struct Send < Punch::Command
      alias Output = Detail | NotFound | AlreadySent | NoLines

      # ...
      def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, grant : Punch::Grant(Send),
               events : Punch::Events(InvoiceSent)) : Output
        # ... save the sent invoice ...
        events.publish(InvoiceSent.new(sent.id, sent.customer_id))
      end
    end
  end

  module Customers
    # Reacts after commit: the customer's pending total is stale.
    struct RecountPending
      include Punch::Subscriber(InvoiceSent)

      alias Output = Nil

      def call(event : InvoiceSent) : Output
        PENDING.delete(event.customer_id)
      end
    end
  end
end
```

## Events

An event is a **struct** that includes `Punch::Event`. Name it in the past tense, for what happened, and give it the IDs and small values a subscriber needs to look up the rest. It is immutable: a class, or a setter, does not compile.

Several events can share a module (`include Audited`) or an abstract struct that includes `Punch::Event`, so one subscriber can listen to all of them. The module itself does not include `Punch::Event`; the events do.

## Publishing

Only a Command publishes. It asks for the handle in `call`, after the handle and any actor or grant, and the type lists every event it may publish:

```crystal
def call(input : Input, db : Punch::Writer, events : Punch::Events(NoteRemoved | NoteArchived)) : Nil
  events.publish(NoteArchived.new(input.note_id))
end
```

That type is the declaration. `punch events` reads it, and publishing an event outside it does not compile. A Query or a Page that asks for `Punch::Events` does not compile either; neither does a type in it that is not an event. Never make a handle by hand: `Punch/EventsHandle` reports it, because `punch events` could not see the event.

## Delivery

| Delivery | Declared | Runs | `call` |
|---|---|---|---|
| after commit | default | once the Command's transaction has committed, in the request's fiber, before the response | `call(event) : Nil` |
| inline | `@[Punch::Subscriber::Delivery(:inline)]` | inside `publish`, in the Command's transaction | `call(event, db : Punch::Writer) : Nil` |
| deferred | `@[Punch::Subscriber::Delivery(:deferred)]` | as a durable job: written to the outbox in the Command's transaction, run by a worker after the commit | `call(event, job : Punch::Job::Context) : Punch::Job::Result` |

- **After commit** is for reactions that must see committed data and must not fail the Command: cache invalidation, metrics, and live updates later. For cache invalidation, `@[Punch::Subscriber::Forget(STORE, key: getter)]` writes the subscriber's `call` and shows the store in `punch events` (`docs/cache.md`). If the Command returns a failure (its writes roll back) or raises, or the commit fails, nothing is delivered. A subscriber that raises is logged, its span is marked failed, and `punch.events.failed` is counted on the wide event; the other subscribers and the response go on, because the data is already committed. Keep these fast: they run before the response is sent. Anything slow or retryable is deferred.
- **Deferred** is for anything slow, retryable, or outside: mail, webhooks, calls to other systems. One outbox entry per subscriber and event is written in the Command's transaction (docs/jobs.md), so the job exists exactly when the data does; it runs as a job of type `Subscriber(Event)`, with the event as its payload, retried with backoff, and at least once: make it safe to repeat. It takes `@[Punch::Job::Options]` and `@[Punch::Job::Concurrency]` like a job (`by:` names a field of the event). Events with deferred subscribers are JSON payloads, so keep them to IDs and small values. Their shape is recorded in `payloads.lock.json` like a job's, and a breaking change raises the event's version with `@[Punch::Payloads::Version(2, from: {1 => V1})]` and a frozen type ([Payloads across deploys](jobs.md#payloads-across-deploys)); a subscriber always gets the current shape.
- **Inline** is for the rare projection that must stay consistent with the data. It writes in the Command's transaction. If it raises, the Command fails and everything rolls back (500). Rules the Command must act on are not subscribers: call them explicitly.

Subscribers of one event run in name order: inline ones during `publish`, the others after the commit, event by event in publishing order. A subscriber is made with `new` for each event, so it keeps no state. Include `Punch::Subscriber(T)` once per type listened to.

These do not compile: a subscriber to a type that is no event and that no event includes or inherits; an inline subscriber without `call(event, db : Punch::Writer)`; an after-commit subscriber without `call(event)`; a deferred subscriber without `call(event, job : Punch::Job::Context)`; job options on a subscriber that is not deferred.

**Not yet:** subscribers do not publish events themselves, and a deferred subscriber's own writes publish nothing either (core flow stays explicit). An after-commit subscriber gets no database handle; a live update that needs to read is a page's `live` instead (`docs/views.md`).

## The graph

```
$ punch events
Billing::InvoicePaid
  published by  Billing::Payments::Webhook
  after_commit  Billing::Customers::ForgetStatement

Billing::InvoiceSent
  published by  Billing::Invoices::Send
  after_commit  Billing::Customers::ForgetStatement
  deferred      Billing::Invoices::MailInvoice
```

`punch events` builds the app and asks its binary (`bin/app events`); `--json` gives `{"events": [{"event", "publishers", "subscribers": [{"subscriber", "delivery"}]}]}`. Every concrete event appears, published or not.

`punch check` fails when an event has no publisher (step `events`): the event is dead, and so are its subscribers.

## Tracing

Each publish is a span `publish Billing::InvoiceSent` below the write transaction, with `punch.event`; inline subscribers are spans below it. Each after-commit run is a span named after the subscriber, below the operation's span, after the transaction's. Both carry `punch.subscriber` and `punch.delivery`. The wide event counts `punch.events.published` and `punch.events.failed`.

## Specs

```crystal
sent = Punch::Spec.published(Billing::InvoiceSent) { client.post(Invoices::Send.path(invoice_id: id)) }
sent.map(&.customer_id).should eq([customer])
```

The matcher says the same in one line, with a readable failure that lists what was published instead:

```crystal
-> { client.post(Invoices::Send.path(invoice_id: id)) }.should publish(Billing::InvoiceSent, invoice_id: id, times: 1)
-> { client.post(Invoices::Send.path(invoice_id: sent)) }.should_not publish(Billing::InvoiceSent)
```

`Punch::Spec.published { }` returns every event delivered after commit while the block ran in this fiber, through `Punch::Spec.client` or a write of the spec's own; with a type, only those. A failed Command delivers nothing, so its events are not there.

To call a Command directly, get its handle with `Punch::Spec.events(Command, writer)`:

```crystal
db.write do |writer|
  Send.new.call(input, writer, actor, Punch::Spec.grant(Send, actor, writer, invoice_id: id), Punch::Spec.events(Send, writer))
end
```

Test a subscriber by calling it: `ForgetStatement.new.call(event)`. Deferred subscribers run with `Punch::Spec.perform_jobs` (docs/jobs.md). To check what a Command publishes or enqueues, use `->{ … }.should publish(T, field: value)` and `should enqueue` (docs/jobs.md).
