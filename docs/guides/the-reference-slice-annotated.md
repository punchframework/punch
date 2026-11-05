# The Reference Slice, Annotated

Applies to Punch 0.1.

Each topic guide shows one piece of an app. This guide shows how the pieces fit, by reading one complete entity of the reference app, invoices, file by file, in the order you would write it. It is the walkthrough for writing a slice by hand, and the human counterpart of what a coding agent copies. Invoices are the most demanding entity in the app: they have states, money, a policy, an event, a job, mail, and pages. Most entities need less, and the end of this guide says what you can leave out.

After reading this guide, you will know:

- in which order to write an entity, and why that order works;
- what each file holds, and what it leaves to the others;
- how a state, a rule, and a failure travel from the model to the HTTP response;
- how an event, a job, and a mail hang off one Command;
- what to leave out when an entity is simpler.

Before you start: you have built an app ([Getting Started with Punch](getting-started.md)). The guide is easiest after the guides on operations, models, and pages, which it links to section by section. Every file below is in `reference/app/billing/invoices/`, in the shard at `lib/punch/reference/`.

## The map of the entity

An entity is a directory that owns tables. The slice `billing` holds customers, invoices, and payments, and `invoices` looks like this:

```text
app/billing.cr               what the billing slice means
app/billing/events.cr        the slice's events
app/billing/invoices.cr      what an invoice means
app/billing/invoices/
  types.cr                   IDs and domain primitives
  columns.cr                 which column holds which type
  queries.sql                the named queries
  invoice.cr                 the model: one type per state
  store.cr                   states to rows and back
  results.cr  inputs.cr      what operations answer and share
  policies.cr                who may touch one invoice
  operations/                one Query or Command per file
  subscribers/  jobs/  mail/ what happens around them
  pages/  components.cr      HTML, and markdown for agents
```

You write it from the inside out: first what an invoice means, then how it is stored, then what it can do, and only then how the outside world reaches it. Each step type-checks before the next, so `punch typecheck` keeps you honest all the way.

## The outline: what it means

Start with words. An outline is the documented module beside the directory. It says what the entity is, as someone who knows the business would say it, and leaves out what the code already tells:

```crystal source=reference/app/billing/invoices.cr
# app/billing/invoices.cr
# An invoice is an organization's request that a customer pay for what
# it delivered: lines of work or goods, priced in one currency.
#
# It starts as a draft, which the organization may change or discard
# as it likes. Sending it to the customer makes it binding: it gets its
# number, falls due after the payment term, and never changes again. A
# payment of its amount settles it; a sent invoice still unpaid after
# its due date is overdue, and the customer is reminded.
#
# Invoices are what the rest of billing turns on: a customer owes what
# its sent invoices add up to, and payments exist to settle them.
module Billing::Invoices
  # How long a customer has to pay a sent invoice.
  PAYMENT_TERM = 14.days
end
```

This is the first thing a reader or an agent opens, and the only place the lifecycle is told as a story. The one constant is here because everything about an invoice shares it. `punch generate entity billing/invoices` writes the empty outline, with `types.cr`, `columns.cr`, and `queries.sql`.

## The migration and the column types

The table comes next, as a migration in plain SQL. It went through several migrations, so `db/schema.sql` shows it best. The table is `STRICT`, and what the database can guarantee, it does: the composite foreign key keeps a customer of another organization out, and the `CHECK` keeps a draft from having a number. A paid invoice is a sent one with a row in `invoice_payments`, so the table has no `paid` status:

```sql illustrative="the invoices table of reference/db/schema.sql"
CREATE TABLE invoices (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  organization_id INTEGER NOT NULL REFERENCES organizations (id),
  customer_id     INTEGER NOT NULL,
  currency        TEXT    NOT NULL,
  status          TEXT    NOT NULL,
  number          TEXT    UNIQUE,
  sent_at         TEXT,
  due_at          TEXT,
  created_at      TEXT    NOT NULL, billed_to BLOB,
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  CHECK (
    (status = 'draft' AND number IS NULL AND sent_at IS NULL AND due_at IS NULL) OR
    (status = 'sent' AND number IS NOT NULL AND sent_at IS NOT NULL AND due_at IS NOT NULL)
  )
) STRICT;
```

The domain's types come before the mapping, in `types.cr`. A number is not a string but a `Number`, which can only hold a valid one:

```crystal source=reference/app/billing/invoices/types.cr select=Billing::Invoices::Number
# app/billing/invoices/types.cr
module Billing::Invoices
  # ...

  # The number a sent invoice carries, `INV-000042`: assigned in sending
  # order without gaps, at least six digits.
  struct Number
    include Punch::Primitive(String)

    FORMAT = /\AINV-[0-9]{6,}\z/

    def self.json_schema
      {pattern: "^INV-[0-9]{6,}$"}
    end

    def self.parse(raw : String) : self | Punch::Invalid
      FORMAT.matches?(raw) ? new(raw) : Punch::Invalid.new("invalid_invoice_number")
    end

    # The number after *sequence*, the numeric part of the last one issued.
    def self.next(sequence : Int64) : self
      new("INV-#{(sequence + 1).to_s.rjust(6, '0')}")
    end
  end

  # ...
end
```

Then `columns.cr` says which column holds which type, once, and every query and record generated from it follows ([Column types, once](named-queries.md#column-types-once-columnscr)):

```crystal source=reference/app/billing/invoices/columns.cr
# app/billing/invoices/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

# Who a sent invoice bills, as the customer was when it was sent: kept with
# the invoice, encrypted as a whole, so a later edit of the customer
# changes no sent invoice (lib/punch/docs/composites.md).
Punch.composite Billing::Invoices::BilledTo,
  customer_id: Billing::Customers::ID,
  name: Punch::NonEmptyString,
  company_name: Punch::NonEmptyString?,
  address: Punch::NonEmptyString?,
  tax_id: Billing::Customers::TaxID?

Punch.table "invoices", Billing::Invoices,
  id: Billing::Invoices::ID,
  organization_id: Accounts::Organizations::ID,
  customer_id: Billing::Customers::ID,
  currency: Punch::Currency,
  number: Billing::Invoices::Number,
  sent_at: Time,
  due_at: Time,
  billed_to: Punch::Encrypted(Billing::Invoices::BilledTo),
  created_at: Time

Punch.table "invoice_lines", Billing::Invoices::Lines,
  id: Billing::Invoices::Lines::ID,
  invoice_id: Billing::Invoices::ID,
  description: Punch::NonEmptyString,
  quantity: Billing::Invoices::Quantity,
  unit_price: Punch::Money

Punch.table "invoice_payments", Billing::Invoices::Payments,
  invoice_id: Billing::Invoices::ID,
  reference: Punch::NonEmptyString,
  amount: Punch::Money,
  paid_at: Time

Punch.table "invoice_reminders", Billing::Invoices::Reminders,
  invoice_id: Billing::Invoices::ID,
  created_at: Time
```

`billed_to` is encrypted as a whole, because a name and an address on an invoice are personal data ([Column Encryption and Blind Indexes](column-encryption.md)). It is a composite: a value of several fields, kept as the customer was when the invoice was sent ([Composites](composites.md)).

## The queries: only what `Table` does not

`punch db:generate` gives every mapped table a `Table` module that finds, inserts, updates, and deletes one row. So `queries.sql` holds what is left. Each named query says why it exists, and the doc comment becomes the method's:

```sql illustrative="three queries of reference/app/billing/invoices/queries.sql"
-- name: Organization :one
-- Which organization an invoice belongs to, for the policy.
SELECT organization_id FROM invoices WHERE id = :invoice_id;

-- name: LastSequence :one
-- The numeric part of the last invoice number issued, 0 before the first.
SELECT coalesce(max(CAST(substr(number, 5) AS INTEGER)), 0) AS sequence
FROM invoices
WHERE number IS NOT NULL;

-- name: AddReminder :execrows
-- Records that a sent invoice came due, once per invoice: a reminder job
-- that runs twice writes one row.
INSERT INTO invoice_reminders (invoice_id, created_at) VALUES (:invoice_id, :created_at)
ON CONFLICT (invoice_id) DO NOTHING;
```

The list is a `:page` query with declared clauses for its filters ([Keeping SQL Safe and Fast](keeping-sql-safe-and-fast.md)). Every query must pass `punch check`'s plan check, so a full scan is a decision you state, as `OverdueWithoutReminder` does with `-- scan:` and its reason.

## The model: one type per state

An invoice has a lifecycle, so it is tier 2: each state is its own immutable type, and a transition is a method that returns the next state ([Domain Models](domain-models.md#tier-2-one-type-per-state)). Nothing here touches the database, so all of it is tested without one.

```crystal source=reference/app/billing/invoices/invoice.cr select=Billing::Invoices::Invoice::Draft
# app/billing/invoices/invoice.cr
# Tier 2 (lib/punch/docs/models.md): an invoice has a lifecycle, and its state decides what
# may happen to it. Each state is its own immutable type; a transition is a
# method that returns the next state. Invoices::Store turns rows into these
# types and back. Nothing here touches the database.
module Billing::Invoices::Invoice
  # ...

  # Being written: can be revised, sent, or deleted.
  record Draft,
    id : Invoices::ID,
    customer_id : Customers::ID,
    currency : Punch::Currency,
    lines : Array(Line),
    created_at : Time do
    include Billed

    def status : Status
      Status::Draft
    end

    def revise(*, currency : Punch::Currency = @currency, lines : Array(Line) = @lines) : Draft
      copy_with(currency: currency, lines: lines)
    end

    # Issues the invoice under *number*, billing the customer as
    # *billed_to* says. An invoice without lines cannot be sent.
    def send(number : Invoices::Number, at : Time, billed_to : BilledTo) : Sent | NoLines
      return NoLines.new if lines.empty?

      Sent.new(id, customer_id, currency, lines, created_at, number: number, sent_at: at, due_at: at + Invoices::PAYMENT_TERM, billed_to: billed_to)
    end
  end

  # ...
end
```

This is where illegal states stop compiling. Only `Draft` has `send`, so nothing can send a paid invoice. Its answer is `Sent | NoLines`, so a caller has to handle both. A `Sent` has a number and a due date as non-nil fields, while a draft has neither field to forget. `NoLines` here is a plain record, a fact of the domain. It knows nothing about HTTP, and the operation turns it into a problem.

What every state has goes in a module, `Billed`, and a rule that lists and details share goes in `Due`, so the two can never disagree about what overdue means:

```crystal source=reference/app/billing/invoices/invoice.cr select=Billing::Invoices::Invoice::Due
# app/billing/invoices/invoice.cr
# Tier 2 (lib/punch/docs/models.md): an invoice has a lifecycle, and its state decides what
# may happen to it. Each state is its own immutable type; a transition is a
# method that returns the next state. Invoices::Store turns rows into these
# types and back. Nothing here touches the database.
module Billing::Invoices::Invoice
  # ...

  # Whether an invoice is unpaid past its due date. Included by `Sent`,
  # `Paid`, and the rows of the list queries (`-- include
  # Billing::Invoices::Invoice::Due`), so lists and details share one rule; a draft
  # row has no due date and is never overdue.
  module Due
    abstract def due_at : Time?
    abstract def paid_at : Time?

    def overdue?(now : Time) : Bool
      due = due_at
      due && paid_at.nil? ? now > due : false
    end
  end

  # ...
end
```

## The store: rows to states and back

The model does not know the database, and generated code does not know states. The store is the one place that knows both ([The store](domain-models.md#the-store)):

```crystal source=reference/app/billing/invoices/store.cr select=Billing::Invoices::Store#load
# app/billing/invoices/store.cr
# Loads and saves Billing::Invoices::Invoice states with the generated queries. Call
# it inside one `read` or `write`, so a load and the save after it see the
# same data (lib/punch/docs/models.md).
module Billing::Invoices::Store
  # ...

  def load(db : Punch::Reader | Punch::Writer, id : ID) : Invoice::Any?
    row = Table.find(db, id) || return
    lines = Queries.lines(db, invoice_id: id).map do |line|
      Invoice::Line.new(line.description, line.quantity, line.unit_price)
    end
    payment = row.status == "sent" ? Queries.payment(db, invoice_id: id) : nil

    case status(row.status, id, payment.try(&.paid_at))
    in .draft?
      Invoice::Draft.new(row.id, row.customer_id, row.currency, lines, row.created_at)
    in .sent?
      Invoice::Sent.new(row.id, row.customer_id, row.currency, lines, row.created_at,
        number: row.number || missing(id, "number"),
        sent_at: row.sent_at || missing(id, "sent_at"),
        due_at: row.due_at || missing(id, "due_at"),
        billed_to: row.billed_to.try(&.unwrap))
    in .paid?
      payment ||= missing(id, "invoice_payments")
      Invoice::Paid.new(row.id, row.customer_id, row.currency, lines, row.created_at,
        number: row.number || missing(id, "number"),
        sent_at: row.sent_at || missing(id, "sent_at"),
        due_at: row.due_at || missing(id, "due_at"),
        billed_to: row.billed_to.try(&.unwrap),
        paid_at: payment.paid_at, payment_reference: payment.reference)
    end
  end

  # ...
end
```

This is where a stored status turns into a type. From here on, operations branch on the state types this method returns, never on a status string. A row that breaks the model, such as a sent invoice without a number, raises through `missing`, because that is a bug and not an outcome.

Call a store inside one `read` or `write`, so a load and the save after it see the same data.

## Results and policies: the shapes at the edge

Now the outside. `results.cr` holds what operations answer. A result is its own struct, never a record, so the API does not change when a column does. `Detail` is the full invoice, with its status code as an annotation. A failure is a struct that includes `Punch::Problem`:

```crystal source=reference/app/billing/invoices/results.cr select=Billing::Invoices::NotFound,Billing::Invoices::AlreadySent
# app/billing/invoices/results.cr
module Billing::Invoices
  # ...

  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end

  # A sent invoice is final, also once it is paid.
  @[Punch::Status(409)]
  struct AlreadySent
    include Punch::Problem

    getter number : Number
    getter sent_at : Time

    def initialize(invoice : Invoice::Issued)
      @number = invoice.number
      @sent_at = invoice.sent_at
    end
  end
end
```

`AlreadySent` carries fields, so the client learns the number the invoice already has. Punch writes the Problem Details document and its code, `already_sent`, from the type ([Results, Errors, and Status Codes](results-errors-and-status-codes.md)).

The policy decides who may touch one invoice. It takes the path parameter by name:

```crystal source=reference/app/billing/invoices/policies.cr
# app/billing/invoices/policies.cr
module Billing::Invoices
  # Whoever holds a role on the invoice's organization that permits the
  # operation (`Accounts::Roles`): a member sees an invoice but may not
  # send it (403), and to anyone without a role there it does not exist
  # (404).
  struct ByRole
    include Punch::Policy

    def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *,
                   invoice_id : ID) : Punch::Policy::Decision
      organization = Queries.organization(db, invoice_id: invoice_id) || return not_found
      Punch::Roles.check(db, actor.user.id, operation, on: organization.organization_id)
    end
  end
end
```

A member of the organization sees an invoice but may not send it, and gets 403. To anyone without a role there, it does not exist, and they get 404, so the answer does not reveal that the ID is in use ([Authorization and Roles](authorization-and-roles.md)). The policy is one indexed lookup, since it runs on every request.

## Operations: the middle of the slice

Operations are thin: load, ask the model, save, announce. `Show` is the shortest:

```crystal source=reference/app/billing/invoices/operations/show.cr
# app/billing/invoices/operations/show.cr
module Billing::Invoices
  @[Punch::Authorize(ByRole)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Invoicing::Actor) : Output
      invoice = Store.load(db, input.invoice_id)
      invoice ? Store.detail(db, invoice, Time.utc) : NotFound.new
    end
  end
end
```

The name decides the route: `Show` in `Billing::Invoices` is `GET /billing/invoices/:invoice_id` ([Operations and Routing](operations-and-routing.md)). `alias Output` lists every way it can end, and the compiler checks each has a status. `Show` is a Query, so its handle is a `Punch::Reader` and it cannot write.

`Send` shows the whole pattern:

```crystal source=reference/app/billing/invoices/operations/send.cr
# app/billing/invoices/operations/send.cr
module Billing::Invoices
  # An invoice without lines cannot be sent.
  @[Punch::Status(422)]
  struct NoLines
    include Punch::Problem
  end

  # Sends a draft: it gets the next invoice number and is due after the
  # payment term, and it keeps the customer's name and address as they
  # are now. Only a draft with lines can be sent. Each user sends at most
  # 30 an hour, since each one mails a customer (`MailInvoice`). A client
  # must name each attempt with an idempotency key, so a retry after a
  # lost answer gets that answer instead of `already_sent`.
  @[Punch::Authorize(ByRole)]
  @[Punch::RateLimit(30, per: 1.hour, by: :actor)]
  @[Punch::Idempotency(:required)]
  struct Send < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = Detail | NotFound | AlreadySent | NoLines

    def call(input : Input, db : Punch::Writer, _actor : Invoicing::Actor, _grant : Punch::Grant(Send),
             events : Punch::Events(InvoiceSent), jobs : Punch::Jobs(Remind)) : Output
      case invoice = Store.load(db, input.invoice_id)
      in Nil                          then NotFound.new
      in Invoice::Sent, Invoice::Paid then AlreadySent.new(invoice)
      in Invoice::Draft
        now = Time.utc

        # The customer is there: the foreign key keeps it while an invoice is.
        customer = Customers::Table.find(db, invoice.customer_id) || return NotFound.new
        case sent = invoice.send(Store.next_number(db), now, BilledTo.of(customer))
        in Invoice::NoLines then NoLines.new
        in Invoice::Sent
          Store.save(db, sent)
          events.publish(InvoiceSent.new(sent.id, sent.customer_id))
          # Through the outbox: the reminder exists exactly when the sent invoice does.
          jobs.enqueue(Remind.new(sent.id), at: sent.due_at)
          Store.detail(db, sent, now)
        end
      end
    end
  end
end
```

- **The annotations** are who, how often, and that a client names each attempt. The rate limit is there because each send mails someone.
- **`NoLines`** is defined here, because only `Send` returns it, and it shares a name with the model's fact. `Send` turns one into the other.
- **The arguments of `call`** are its effects: it can write, and it can publish `InvoiceSent` and enqueue `Remind`, and nothing else. `_grant : Punch::Grant(Send)` proves that the policy ran.
- **The two `case … in`** are exhaustive. A new state stops this file compiling until it says what sending that state does.
- **`|| return NotFound.new`** handles the nil, where `not_nil!` would not pass the lint.
- **The event and the job** go into the same transaction as the invoice. If the save fails, neither exists.

A failure result rolls the transaction back, so `Send` needs no cleanup path.

## Events: what happened

An event is a fact, in the past tense, with the IDs a subscriber needs. Events live in the slice, not the entity, because other entities listen. `InvoiceSent` includes two marker modules, so a subscriber that cares about any change to a balance hears it without naming it ([Domain Events](domain-events.md)):

```crystal source=reference/app/billing/events.cr select=Billing::InvoiceSent
# app/billing/events.cr
module Billing
  # ...

  # An invoice was issued to its customer: numbered, final, and due.
  # Published by `Invoices::Send` once the invoice is saved.
  record InvoiceSent,
    invoice_id : Invoices::ID,
    customer_id : Customers::ID do
    include Punch::Event
    include BalanceChanged
    include InvoiceChanged
  end

  # ...
end
```

`Send` does not mail anyone. It says what happened, and what follows is a subscriber's business. That keeps the Command small, and lets a mail fail and retry without touching the invoice.

## Subscribers, jobs, and mail: what happens after

`MailInvoice` is a deferred subscriber: a job through the outbox, so it runs after the commit, and is retried when delivery fails:

```crystal source=reference/app/billing/invoices/subscribers/mail_invoice.cr
# app/billing/invoices/subscribers/mail_invoice.cr
module Billing::Invoices
  # Mails a sent invoice to its customer. Deferred (lib/punch/docs/events.md): a job
  # through the outbox, so the mail goes out exactly when the invoice was
  # sent, after the response, and is retried if delivery fails.
  #
  # The mail is in the customer's language, else in the organization's,
  # else in the app's default.
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct MailInvoice
    include Punch::Subscriber(InvoiceSent)

    def call(event : InvoiceSent, job : Punch::Job::Context) : Punch::Job::Result
      invoice, customer = job.read { |db| {Store.load(db, event.invoice_id), Customers::Table.find(db, event.customer_id)} }
      return discard("invoice #{event.invoice_id} is gone") unless invoice.is_a?(Invoice::Issued) && customer

      expires_at = Time.utc.at_beginning_of_second + Sharing::VALID
      link = SharedPage.href(token: Sharing.token(invoice, expires_at))
      locale = Punch::I18n.locale((customer.locale || Accounts::Mailing.organization_locale(job, customer.organization_id)).try(&.to_s))
      mail = InvoiceMail.new(invoice, customer, link, Invoicing::Credentials.current.issuer.name.value)
      Punch::Mailer.deliver(mail, locale: locale, job: job)
    end
  end
end
```

It loads the invoice again, since the payload holds only IDs, and it discards when the invoice is gone, because retrying would not bring it back. The mail itself is a component ([Mail](mail.md)):

```crystal source=reference/app/billing/invoices/mail/invoice_mail.cr
# app/billing/invoices/mail/invoice_mail.cr
module Billing::Invoices
  # The mail that brings a sent invoice to its customer: the amount, the
  # due date, and a link that shows the invoice without signing in.
  struct InvoiceMail
    include Punch::Mail

    def initialize(@invoice : Invoice::Issued, @customer : Customers::Record, @link : Punch::Href, @issuer : String)
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(@customer.email_encrypted.unwrap, @customer.display_name)
    end

    def subject(locale : Punch::Locale) : String
      locale.t.invoices.mail.subject(number: @invoice.number.to_s, issuer: @issuer)
    end

    def view(v : Punch::View) : Nil
      t = v.t.invoices.mail
      number = @invoice.number.to_s
      v.p t.greeting(name: @customer.display_name)
      v.p t.body(number: number, total: v.locale.money(@invoice.total, @invoice.currency), due: v.locale.date(@invoice.due_at, :long))
      v.p { v.a t.open(number: number), href: @link }
      v.p t.validity
      v.p do
        v.text t.closing
        v.br
        v.text @issuer
      end
    end
  end
end
```

`Remind` is a plain job. `Send` enqueues it for the due date, and a job runs at least once, so it must be safe to run twice. Here, `AddReminder` writes one row however often it runs ([Background Jobs](background-jobs.md#jobs-run-at-least-once)):

```crystal source=reference/app/billing/invoices/jobs/remind.cr
# app/billing/invoices/jobs/remind.cr
module Billing::Invoices
  # Comes due with its invoice: `Send` enqueues it through the outbox for
  # the due date (lib/punch/docs/jobs.md). It records a reminder for an invoice that
  # is still unpaid; it mails nothing (the invoice itself is mailed by
  # `MailInvoice`). Safe to run twice: an invoice has one
  # reminder.
  @[Punch::Job::Options(queue: "reminders")]
  record Remind,
    invoice_id : ID do
    include Punch::Job

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      job.write do |db|
        case invoice = Store.load(db, invoice_id)
        in Nil            then discard("invoice #{invoice_id} was deleted")
        in Invoice::Draft then discard("invoice #{invoice_id} is not sent")
        in Invoice::Paid  then discard("invoice #{invoice_id} is paid")
        in Invoice::Sent
          Queries.add_reminder(db, invoice_id: invoice.id, created_at: Time.utc)
          nil
        end
      end
    end
  end
end
```

## Pages: the same operations for people

A page calls the operation it shows, and renders a component with the result. It shares the operation's input, its path, and its policy:

```crystal source=reference/app/billing/invoices/pages/show_page.cr select=Billing::Invoices::ShowPage
# app/billing/invoices/pages/show_page.cr
module Billing::Invoices
  # ...

  # One invoice, as `Show` answers it. A draft can be sent or deleted from
  # here; a refusal (a draft without lines) shows this page again with
  # the reason. Agents read it too, as markdown with the two forms as
  # action blocks. Open in a browser, it shows a change made elsewhere
  # (sent, paid, revised, deleted) by refreshing itself.
  @[Punch::AgentReadable]
  @[Punch::Authorize(ByRole)]
  @[Punch::Forms(Send, Destroy)]
  struct ShowPage < Punch::Page
    alias Input = Show::Input

    alias Output = DetailView | NotFound

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      case detail = Show.new.call(input, db, actor)
      in NotFound then detail
      in Detail   then DetailView.new(detail, actor)
      end
    end

    def live(event : InvoiceChanged, input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Punch::TurboStream?
      Punch::TurboStream.build(&.refresh) if event.invoice_id == input.invoice_id
    end

    # After a deleted draft, the list; after sending, this page again.
    def self.redirect(result : Nil) : Punch::Href
      IndexPage.href
    end
  end
end
```

- **`call`** runs `Show`, so a page holds no logic of its own and cannot show what the API would refuse.
- **`@[Punch::Forms(Send, Destroy)]`** says the forms on this page post to those Commands. A refusal shows this page again with the reason ([Forms](forms.md)).
- **`@[Punch::AgentReadable]`** serves the same page as markdown, with its forms as action blocks ([Pages for Agents](pages-for-agents.md)).
- **`live`** refreshes an open page when an event about this invoice arrives ([Turbo Frames, Streams, and Live Pages](turbo-frames-streams-and-live-pages.md)).

A component is a struct with a `view` method, written with HTML element names. A component only one page uses lives in that page's file, and one that several pages render goes in `components.cr` ([Pages and Components](pages-and-components.md)):

```crystal source=reference/app/billing/invoices/components.cr select=Billing::Invoices::AddressLines
# app/billing/invoices/components.cr
module Billing::Invoices
  # ...

  # An address as a definition in a list of facts: one line each, the
  # way it is written on an envelope.
  struct AddressLines
    include Punch::Component

    def initialize(@lines : Array(String))
    end

    def view(v : Punch::View) : Nil
      v.dd do
        @lines.each_with_index do |line, index|
          v.br if index > 0
          v.text line
        end
      end
    end
  end

  # ...
end
```

Text comes from `v.t`, and amounts and dates from `v.locale`, so no sentence is a string literal and no format is hand-written.

## Specs: from the inside out

Specs mirror the files, and each level tests what only it can:

- **The model,** without a database: `spec/billing/invoices/invoice_spec.cr` sends a draft and checks the number and the due date.
- **Operations,** through the real router, so the contract check runs against `openapi.json`: `spec/billing/invoices/send_spec.cr`.
- **Pages,** as HTML and as markdown: `show_page_spec.cr`.
- **Jobs and mail,** by running them: `remind_spec.cr`, `mail_invoice_spec.cr`.

An operation spec reads like a use of the API. This one tests the outcome, then the refusal:

```crystal illustrative="an example from reference/spec/billing/invoices/send_spec.cr, shortened"
it "sends a draft once, numbering invoices in sending order" do
  client = AccountsSpec.client
  customer = customer_id(client)
  first, second = draft(client, customer), draft(client, customer)

  sent = client.post(Billing::Invoices::Send.path(invoice_id: second), headers: Punch::Spec.idempotency_key)
  sent.status.should eq(HTTP::Status::OK)
  {sent.json["status"], sent.json["number"]}.should eq({"sent", "INV-000001"})

  again = client.post(Billing::Invoices::Send.path(invoice_id: second), headers: Punch::Spec.idempotency_key)
  again.status.should eq(HTTP::Status::CONFLICT)
  {again.json["code"], again.json["number"]}.should eq({"already_sent", "INV-000001"})
end
```

Test the app's decisions: which result, which policy, which rule. What Punch guarantees, such as a required field being required, is not yours to test ([Testing Punch Applications](testing-punch-applications.md#what-to-test-at-which-level)).

## Writing your own entity

The order above works for any entity:

1. `punch db:migration create_<table>`, then `punch db:migrate`.
2. `punch generate entity <slice>/<entity>`, and write the outline.
3. Domain types in `types.cr`, then `columns.cr`, then `punch db:generate`.
4. If it has a lifecycle, the state types and a store. Add specs for the model now.
5. Results and a policy.
6. One operation at a time, with its spec. Run `punch typecheck` after each edit.
7. Events and what follows them.
8. Pages, components, and texts in `config/locales/`.
9. `punch check`.

Most entities need less than invoices. Leave out what you have no reason for:

| Leave out | When |
|---|---|
| `invoice.cr`, `store.cr` | The entity has no lifecycle: the generated record, with behaviour in `record.cr` if it needs any, is enough (tier 1) |
| `queries.sql` | `Table` does everything |
| `policies.cr` | A shared policy fits, such as `Punch::SignedIn` |
| Events, subscribers, jobs, mail | Nothing happens after the Command |
| Pages | The entity is API only |
| `results.cr` | One operation uses each result, so it can sit in that operation's file |

## Common mistakes

**Starting from the page.** A page written first pulls queries and rules into itself, and the next surface has to repeat them. Write the operation first, and let the page call it.

**Returning a record from an operation.** Every new column would become part of the API. It does not compile:

```crystal fails=spec/fail/record_as_response.cr
# A generated `Record` is a database row, not a wire type: returning one in
# a result does not compile, and says what to return instead.
module Customers
  struct Found
    include JSON::Serializable
    getter customer : Ledger::Customers::Record

    def initialize(@customer : Ledger::Customers::Record)
    end
  end

  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Found
      raise "never run"
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
Punch::Routing.render(Customers::Found.allocate, Punch::HTTP::Context.allocate)
```

```text
Ledger::Customers::Record is a database row, not a response: return a result struct with the fields to show
```

Write a result struct with the fields to show.

**Branching on a status string.** An operation that checks `row.status == "sent"` loses the compiler's help when a state is added. Load through the store and `case … in` over the state types ([Branch on types, not on statuses](domain-models.md#branch-on-types-not-on-statuses)).

**Doing the follow-up inside the Command.** A mail sent in `call` goes out even when the transaction later fails, and it holds the writer while it waits. Publish an event, or enqueue a job.

**Putting HTTP in the model.** `Invoice::NoLines` knows no status. Keeping that apart is what lets the model run in a spec, a job, or a seed.

**A policy per page.** A page shares its operation's policy, so the two cannot disagree. A page with a different policy from its operation is a bug waiting to be shown.

## Limits

- The reference app is an example, not a template: it shows every feature in one place, and a real entity uses fewer.
- There is no generator for operations or pages. `punch generate` writes the entity's frame, and you write the rest, usually by copying from here.
- This guide quotes less than the slice holds. Read the files for the list page, `Create`, `Update`, and sharing links.

## Rules

- Write an entity from the inside out: outline, types, queries, model, operations, then pages. ([Writing your own entity](#writing-your-own-entity))
- Say what an entity means in its outline. ([The outline: what it means](#the-outline-what-it-means))
- Give a lifecycle one type per state, and keep the database out of the model. ([The model: one type per state](#the-model-one-type-per-state))
- Keep operations thin: load, ask the model, save, announce. ([Operations: the middle of the slice](#operations-the-middle-of-the-slice))
- Answer with result structs, never records. ([Results and policies: the shapes at the edge](#results-and-policies-the-shapes-at-the-edge))
- Publish what happened, and let subscribers do what follows. ([Events: what happened](#events-what-happened))
- Let a page call its operation. ([Pages: the same operations for people](#pages-the-same-operations-for-people))
- Test decisions at the lowest level that can see them. ([Specs: from the inside out](#specs-from-the-inside-out))

## Reference

- [Application Structure](application-structure.md) and [Structure](../structure.md): the rule for where each file goes.
- [Models](../models.md), [Operations](../operations.md), [Queries](../queries.md), and [Views](../views.md): every option of each piece.
- `reference/README.md`: what else the reference app shows.
- Next: [Working with Coding Agents](working-with-coding-agents.md), or your own slice.
