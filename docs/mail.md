# Mail

Learn it in: [Mail](guides/mail.md).

A mail is a component with recipients and a subject, delivered by a job. One view yields both parts of the message: HTML from the HTML backend and plain text from the text backend, in the recipient's language. Delivery goes through `Punch::Mailer`, which hands the rendered message to an adapter: Punch's capturing adapter in development and specs, Punch's SMTP adapter, or an adapter the app registers for a provider's API.

## Writing a mail

```crystal
# app/billing/invoices/mail/invoice_mail.cr
struct Billing::Invoices::InvoiceMail
  include Punch::Mail

  def initialize(@invoice : Invoice::Issued, @customer : Customers::Record, @link : Punch::Href, @issuer : String)
  end

  def to : Punch::Mail::Address
    Punch::Mail::Address.new(@customer.email, @customer.display_name)
  end

  def subject(locale : Punch::Locale) : String
    locale.t.invoices.mail.subject(number: @invoice.number.to_s, issuer: @issuer)
  end

  def view(v : Punch::View) : Nil
    t = v.t.invoices.mail
    v.p t.greeting(name: @customer.display_name)
    v.p { v.a t.open(number: @invoice.number.to_s), href: @link }
  end
end
```

- `to` returns one `Punch::Mail::Address` or an array of them; `reply_to` is optional. The sender is the same for every mail and comes from the settings.
- `subject` takes the locale the mail is rendered in. Text comes from the locale files, as everywhere (`docs/translations.md`).
- `view` takes a plain `Punch::View`. There is no `raw`, and a view that takes `Punch::HTMLView` does not compile, because the text part could not show it. A form or `v.document` raises `NestingError`: Punch writes the document around the view, with the subject as its title, and a mail links to the page that has the form. `v.chrome` blocks are left out.
- Links are `SomePage.href(...)` as in pages. In a mail they become absolute URLs below `PUNCH_PUBLIC_URL`.
- No inline styles (the view refuses `style` everywhere), so the HTML part is plain semantic HTML that mail clients show with their own styles.

### The text part

Mail clients show the text part as it is, so it is plain text, not markdown: nothing is escaped, so `Ada <script>` reads as written. The text backend lays the elements out like this:

| Element | Text |
|---|---|
| `h1`, `h2` | The heading, underlined with `=` or `-` |
| `p`, other headings | A paragraph; blocks are separated by a blank line. Whitespace collapses as in HTML; `br` is a line break |
| `a` | `text <https://…/path>`, or the URL alone when the text is the URL |
| `strong`, `b` / `em`, `i` | `*text*` / `_text_` |
| `del`, `s` | `~~text~~`, so struck-out text does not read as current |
| `q` | “text” |
| `ul`, `ol` | `- item` or `1. item`, continuation lines indented |
| `table` | Columns padded to the widest cell, a rule under the head, the caption above |
| `blockquote` | Each line starts with `> ` |
| `dl` | The term, then the description indented by two spaces |
| `pre` | As written |
| `img` | Its `alt` text |

Other elements leave their text as it is. Lines are not wrapped. The markdown backend that agents read is not used here: its escaping would show as backslashes. Check a mail's parts with `Punch::Spec.render_mail(mail, locale)`.

## Sending

Send from a job, normally a deferred subscriber, so the mail goes out through the outbox after the Command committed (`docs/events.md`):

```crystal
@[Punch::Subscriber::Delivery(:deferred)]
@[Punch::Job::Options(queue: "mail")]
struct MailInvoice
  include Punch::Subscriber(InvoiceSent)

  def call(event : InvoiceSent, job : Punch::Job::Context) : Punch::Job::Result
    invoice, customer = job.read { |db| {Store.load(db, event.invoice_id), Customers::Table.find(db, event.customer_id)} }
    return discard("invoice gone") unless invoice.is_a?(Invoice::Issued) && customer

    locale = Punch::I18n.locale(customer.locale.try(&.to_s))
    Punch::Mailer.deliver(InvoiceMail.new(invoice, customer, SharedPage.href(token: ...), issuer), locale: locale, job: job)
  end
end
```

`Punch::Mailer.deliver(mail, locale:, job:)` renders the mail and delivers it now. It takes the job, so mail is only sent from jobs; inside a write transaction it raises. It returns what `perform` returns:

| Result | When |
|---|---|
| `nil` | Delivered |
| `Punch::Job::Retry` | Delivery failed and may succeed later: no connection, STARTTLS or authentication refused, a temporary (4xx) answer, any other refusal, or an exception from a provider's adapter (also recorded as an error) |
| `Punch::Job::Discard` | The server refused the recipient for good (an SMTP 5xx answer to `RCPT`) |

**Locale:** always the recipient's, stored with them, never the request's. The reference app stores one per customer and falls back to the language of the user who owns the customer.

Jobs run at least once, so a mail can go out twice after a crash between sending and recording the job as done. SMTP has no idempotency key; the job's key is on the span (`punch.mail.key`) and in captured mail.

## Settings

The app declares its mail settings as a group in its credentials (`docs/credentials.md`):

```crystal
struct Invoicing::Credentials
  include Punch::Credentials

  getter mail : Punch::Mailer::Settings
end
```

| Credential | Variable | |
|---|---|---|
| `mail.delivery` | `MAIL__DELIVERY` | `capture`, `smtp`, or `adapter`. Required |
| `mail.from` | `MAIL__FROM` | The sender's address. Required |
| `mail.from_name` | `MAIL__FROM_NAME` | The sender's name |
| `mail.smtp.host` | `MAIL__SMTP__HOST` | Required with `delivery: smtp` |
| `mail.smtp.port` | `MAIL__SMTP__PORT` | `587` |
| `mail.smtp.username`, `.password` | `MAIL__SMTP__USERNAME`, `MAIL__SMTP__PASSWORD` | Sent only after TLS |
| `mail.smtp.tls` | `MAIL__SMTP__TLS` | `starttls` (default; the upgrade must succeed, never plain text), `smtps` (TLS from the start, port 465), or `plain` (only for a relay on the same host or network) |

The server's certificate and host name are verified. A setting that does not fit, such as `smtp` without a host, stops the boot with the other credential problems.

**`delivery: adapter`** sends through an adapter the app registers, for a provider's HTTP API. Subclass `Punch::Mailer::Adapter` and register it once, at the top level; it is built at boot, after the credentials loaded:

```crystal
class Invoicing::Postmark < Punch::Mailer::Adapter
  def initialize(@token : Punch::Secret(String))
  end

  def deliver_now(message : Punch::Mailer::Message) : Nil
    # POST message.subject, .from, .to, .reply_to, .text, and .html.value.
    # message.key is stable across retries, for a provider's idempotency key.
  end
end

Punch::Mailer.adapter { Invoicing::Postmark.new(Invoicing::Credentials.current.postmark.token) }
```

Return when the provider accepted the mail. Raise `Punch::Mailer::DeliveryFailed` with `permanent: true` when it refused the recipient for good, and the job discards the mail. Any other exception makes the job retry. An address's `name` is the plain name, for a JSON API; `header_name` is its encoded form, for an adapter that writes headers.

To use a Carbon provider adapter such as `carbon_sendgrid_adapter`, add `carbon` and the adapter's shard to the app, and wrap it:

```crystal
require "punch/mail/carbon"

Punch::Mailer.adapter do
  Punch::Mailer::CarbonAdapter.new(Carbon::SendGridAdapter.new(api_key: Invoicing::Credentials.current.sendgrid.api_key.unwrap))
end
```

**`PUNCH_PUBLIC_URL`** (`docs/tooling.md`, `punch config`) is where people reach the app, such as `https://invoices.example.org`: the base of every link in mail. It defaults to `http://<host>:<port>` in development and test and is required in every other environment.

## Development

With `delivery: capture`, nothing is sent; outside development and test it is a boot problem, as is `tls: plain` with a password to a host other than this machine. The process keeps the newest 500 mails in memory, and the ops console shows them at `/_punch/mail`: sender, recipients, the job's key, the text part as a mail client shows it, and a link to the HTML part.

## Specs

`punch/spec` captures every mail, whatever the settings say, so specs never send. They still need mail settings in `Punch::Spec.credentials`.

```crystal
-> { Punch::Spec.perform_jobs }.should deliver_mail(InvoiceMail, to: "ada@example.org", times: 1)
mail = Punch::Spec.mails(to: "ada@example.org").first
mail.subject.should eq("Invoice A-1 from Example GmbH")
mail.text.should contain("€250.00")
Punch::Spec.client.get(mail.paths.first) # follow the link
```

- `Punch::Spec.mails` are the mails delivered in this example, oldest first; `mails(to:)` filters by recipient.
- A captured mail has `subject`, `from`, `to`, `reply_to`, `text`, `html` (a `SafeHTML`), `locale`, `key`, `type`, `links` (the absolute URLs in the text part), and `paths` (those below `PUNCH_PUBLIC_URL`, for the spec client).
- `Punch::Spec.render_mail(mail, locale)` renders a mail without delivering it.

## Tracing

Each delivery is a `mail.deliver` span of kind client, with `punch.mail.type`, `punch.mail.key`, `punch.mail.adapter`, `punch.mail.recipients` (a count), and `punch.locale`; the job's wide event gets `punch.mail.type`. Addresses, subjects, and bodies are never recorded.

## Rules

`Punch/MailDelivery` reports `Carbon::Email`, `Carbon::DevAdapter`, and `Carbon::SmtpAdapter` outside Punch, and any `deliver_later`: mail is a `Punch::Mail` sent through `Punch::Mailer` from a job. Carbon's provider adapters stay allowed for `Punch::Mailer.adapter`.

