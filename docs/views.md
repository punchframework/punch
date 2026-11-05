# Views and pages

Learn it in: [Pages and Components](guides/pages-and-components.md), [Forms](guides/forms.md), [Turbo Frames, Streams, and Live Pages](guides/turbo-frames-streams-and-live-pages.md), [Pages for Agents](guides/pages-for-agents.md).

Pages are how people use a Punch app in a browser. A page is an endpoint that reads, calls operations, and answers with HTML rendered from components. Components are plain Crystal structs that write HTML element by element; there is no template language, so their arguments are type-checked and a rename is a compile error, not a broken page.

This page covers pages, components, the view, links, forms bound to Commands, Turbo Drive, Frames, and Streams, and pages that agents read as markdown. Stylesheets, images, scripts, and Turbo itself are in `docs/assets.md`.

## Pages

```crystal
module Billing::Invoices
  struct ShowPage < Punch::Page
    alias Input = Show::Input

    alias Output = DetailView | NotFound

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      case detail = Show.new.call(input, db, actor)
      in NotFound then detail
      in Detail
        customer = Customers::Table.find(db, detail.customer_id).try(&.display_name)
        DetailView.new(detail, customer, actor)
      end
    end
  end
end
# GET /billing/invoices/:invoice_id, as HTML
```

A page is a third kind of operation, beside Query and Command:

| | Query | Command | Page |
|---|---|---|---|
| Receives | `Punch::Reader` | `Punch::Writer` | `Punch::Reader` |
| Answers | `GET`, JSON | `POST`, `PATCH`, `DELETE`, JSON | `GET`, HTML |
| In `openapi.json` | yes | yes | no |

- **Input and actor** work as for any operation (`docs/input.md`, `docs/auth.md`). A page usually shares the input of the Query it shows: `alias Input = Show::Input`.
- **Keep pages thin.** A page calls operations and renders their results; the rules stay in the operations and models (HTML endpoints are page-shaped, JSON endpoints resource-shaped, the operations are shared).
- **Results.** `call` returns components, rendered with the status of their `@[Punch::Status]` (200 by default), and failures from 400 on, such as `NotFound`, rendered as Punch's problem page with that status. A result that is neither does not compile: data for programs belongs to a Query.

### Routes

The name ends in `Page`. Without the suffix, the three rules of `docs/operations.md` apply, always with `GET`, plus two names for the pages that hold a Command's form ([Forms](#forms)):

| Page | Route |
|---|---|
| `Billing::Invoices::IndexPage` | `GET /billing/invoices` |
| `Billing::Invoices::ShowPage` | `GET /billing/invoices/:invoice_id` |
| `Billing::Invoices::CreatePage` | `GET /billing/invoices/new` |
| `Billing::Invoices::UpdatePage` | `GET /billing/invoices/:invoice_id/edit` |
| `Billing::Invoices::SendPage` | `GET /billing/invoices/:invoice_id/send` (the Command `Send` is `POST` there) |

`DestroyPage` does not compile; a page that confirms a deletion gets its own name. `@[Punch::Route("GET", "/")]` overrides, as for operations.

**A page and a Query may share a path.** The router picks by `Accept` (RFC 9110, q-values): a client that prefers `text/html`, as every browser does, gets the page; anything else, including no `Accept` and `*/*` (`curl`, `fetch`), gets the JSON. Both answers carry `Vary: Accept`. A path with only a page answers HTML whatever the client asks for. Two pages on one path do not compile.

`punch routes` shows what each route serves:

```
GET   /billing/invoices/:invoice_id  json  Billing::Invoices::Show
GET   /billing/invoices/:invoice_id  html  Billing::Invoices::ShowPage
```

### Problems

| Situation | Answer |
|---|---|
| A result from 400 on (`NotFound`) | Punch's problem page with its status and code |
| A path parameter that does not parse (`/invoices/abc`) | 404: the address names no page |
| A query parameter that does not parse | 422, listing each field and code |
| No actor where the page needs one | 303 to the app's sign-in page (`Punch::Pages.sign_in`, `docs/auth.md`); without one, 401 with `WWW-Authenticate` |
| An unknown path or method, a cross-site Command | A problem page when the client prefers HTML, Problem Details otherwise |

A component can be a failure too: a struct that includes `Punch::Component` and has `@[Punch::Status(410)]` renders itself with that status. The problem page shows the problem's message in the request's locale, with its code (`docs/translations.md`).

In an app, each page has its own file under the slice's `pages/` directory, named after it (`app/billing/invoices/pages/show_page.cr`), with the components only it renders; components several pages share go in the slice's `components.cr` (`docs/operations.md`, `Punch/OperationFile`).

## Components

```crystal
struct LinesTable
  include Punch::Component

  def initialize(@detail : Detail)
  end

  def view(v : Punch::View) : Nil
    v.table(class: "lines") do
      v.thead { v.tr { ["Description", "Amount"].each { |label| v.th label, scope: "col" } } }
      v.tbody do
        @detail.lines.each do |line|
          v.tr do
            v.td line.description.to_s
            v.td Invoices.amount(line.total, @detail.currency)
          end
        end
      end
    end
  end
end
```

- A component includes `Punch::Component`, takes what it shows in its constructor, and writes it in `view(v : Punch::View)`. Render one inside another with `v.render(LinesTable.new(detail))`.
- **Layouts, pages, and partials are all components.** A layout takes the content as a block and writes the document:

  ```crystal
  struct Layout
    include Punch::Component

    def initialize(@title : String)
    end

    def view(v : Punch::View, &) : Nil
      v.document(@title) do
        v.chrome { |chrome| chrome.nav { chrome.a "Invoices", href: Invoices::IndexPage.href } }
        v.main { yield }
      end
    end
  end

  v.render(Layout.new("Invoices")) { v.h1 "Invoices" }
  ```

- `v.document(title, lang: "en", stylesheets: {Punch.asset("app.css")}, script: Punch.asset("application.js"), turbo: true, morph: false)` writes the doctype, `<html lang>`, a head with the character set, the viewport, the title, the stylesheets, the import map, Turbo, and the app's module (`docs/assets.md`), and the block as the body. It must be the outermost element, once. `morph: true` makes Turbo morph the page when it is refreshed (a live page's `refresh`, a form that redirects to the same page), keep the scroll position, and keep the value of the field the viewer is typing in (Turbo's morph would reset it to the server's; Punch loads a small script, `punch/morph.js`, for that). A component that does not call it renders a fragment.
- `v.chrome { |chrome| ... }` holds navigation, scripts, and decoration: written in HTML, left out of the markdown agents read ("Pages agents read"). Put navigation there from the start, so nothing changes when a page becomes agent-readable.

## The view

Element methods carry HTML's names and take their text or a block, with attributes as named arguments:

```crystal
v.h1 "Invoices"
v.p do
  v.text "Total: "
  v.strong total
end
v.ul(class: "lines") { lines.each { |line| v.li line } }
v.div(id: "summary", data: {turbo_frame: "lines"}, aria: {live: "polite"}, hidden: true) { }
v.time date, datetime: sent_at
v.a "Next page", href: Invoices::IndexPage.href(after: last_id), rel: "next"
```

Elements: `div main header footer nav aside section article blockquote fieldset legend details summary p h1`…`h6 pre hr ul ol li dl dt dd table caption thead tbody tfoot tr th td`, and inside text `a span strong em b i s u small mark code kbd samp var abbr cite dfn q time del ins sub sup br wbr`. Forms and their controls are written by `v.form` ([Forms](#forms)), Turbo Frames by `v.frame`. Images: `v.img src: Punch.asset("logo.svg").href, alt: "…"`; `alt` is required, `""` for decoration.

**Text and attribute values are always escaped.** The one way to write markup as it is: `raw(SafeHTML)` on an `HTMLView`, the view `chrome` blocks get. A `Punch::SafeHTML` is made by `SafeHTML.trusted("<svg …>")`, and `Punch/TrustedHTML` reports any argument that is not a string literal, also through an alias, a variable, or a macro, and a reopened `SafeHTML`: markup built from data is built with elements, which escape. `HTTP::Response.html` takes only a `SafeHTML`; the rule reports a `text/html` content type written by hand outside specs.

### Attributes

| Value | Written as |
|---|---|
| `String`, number | `name="value"`, escaped |
| `true` / `false`, `nil` | the bare name / left out |
| `Time` | RFC 3339 |
| `class: ["invoice", ("overdue" if late)]` | the names that are present, space-separated |
| `data: {turbo_frame: "x", turbo: false}` | `data-turbo-frame="x" data-turbo="false"` (booleans as text, as Turbo and Stimulus read them) |
| `aria: {label: "Close"}` | `aria-label="Close"` |

An underscore in a name becomes a hyphen. These do not compile:

- an event handler (`onclick:`) or `style:`: the Content-Security-Policy blocks inline scripts and styles anyway. Use a Stimulus controller or a class;
- a URL attribute (`href`, `cite`, …) with anything but a `Punch::Href`;
- any other value type, such as a typed ID: call `to_s`.

### Nesting

Elements nest as in HTML, narrowed to what markdown can also express, and a mistake raises `Punch::View::NestingError` while rendering, so any spec that renders the component finds it:

- a paragraph, heading, `pre`, `dt`, `caption`, `summary`, and every text element hold only text and text elements;
- a list holds only `li`, a `dl` only `dt` and `dd`; a table only `caption`, `thead`, `tbody`, `tfoot`; those only `tr`; a row only `th` and `td`;
- a link holds no other link and no block.

## Links

Links are typed references to pages, never hand-written URLs:

```crystal
Invoices::ShowPage.href(invoice_id: invoice.id)        # /billing/invoices/inv_gLW26G63FZp
Invoices::IndexPage.href(after: last.id, limit: 20)    # /billing/invoices?after=42&limit=20
Punch::Href.external("https://example.org/terms")      # another site
```

- `SomePage.href` takes every path parameter and any of the input's other fields, each of its field's type, checked at compile time. Values are written as the input parser reads them: enums by snake_case name, times as RFC 3339, arrays as repeated keys, a nested input's fields in brackets (`filter[status]=paid`) without those that hold their default; `nil` leaves a parameter out.
- `Href.external` accepts absolute `https`, `http`, `mailto`, and `tel` URLs and raises on anything else, `javascript:` included. For an address from user data, `Href.external?` returns `nil` instead.
- Commands are not linked; they are reached by forms ([Forms](#forms)).
- On a page that takes the actor, a link to a page the viewer may not open, by that page's policy, is left out with its content; so is a form for a Command the viewer may not run (`docs/authorization.md`).

## Forms

A form is bound to a Command: its action is the Command's typed path, its fields are the Command's input, and what a browser sees after sending it follows Turbo Drive's conventions.

```crystal
struct NewView
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.form(Customers::Create.action) do |form|
      form.field :name, label: "Contact person"
      form.field :company_name, hint: "Invoices are addressed to the company when there is one."
      form.field :email
      form.submit "Add customer"
    end
  end
end

# The page that holds Create's form: GET /billing/customers/new
struct CreatePage < Punch::Page
  struct Input
    include Punch::Input
  end

  alias Output = NewView

  def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
    NewView.new
  end

  # Where the browser goes once Create succeeded.
  def self.redirect(result : Created) : Punch::Href
    IndexPage.href
  end
end
```

### The form

- `Command.action(**path_params)` is the target, checked like `Command.path`. A form can only `POST`; for a `PATCH`, `PUT`, or `DELETE` Command the action carries `?_method=PATCH`, which the router honours for form bodies only. A `PATCH`, `PUT`, or `DELETE` with a form body, as Turbo sends a form with `method="patch"`, is taken as well; `v.form(action, turbo_method: true)` writes that attribute. Without Turbo a browser sends such a form as a `GET`, so `?_method` stays the default.
- `values:` fills the fields, a named tuple checked at compile time against the input: unknown fields, path parameters, and values of the wrong type do not compile. Nested inputs take named tuples, rows arrays of them.
- `form.field :email` writes a `<div class="field">` with the label, the control, the hint, and the errors. The name is a symbol the compiler checks against the input's fields: `form.field :emial` does not compile. `label:` replaces the label, which is `fields.<name>` of the locale files, else made from the name (`company_name` is "Company name", `customer_id` "Customer"; `docs/translations.md`).
- `form.label`, `form.control`, and `form.errors` write the parts alone, for layouts `field` does not fit, such as a table with a row per line.
- `form.each(:lines, LineInput, blank: 3) { |line, index| line.control :description }` writes rows of a nested array: the rows the values hold, then *blank* empty ones. Empty rows are not sent as rows. `form.fields(:address, Address) { |address| ... }` writes one nested input.
- `form.submit "Save"` writes the button. Lay the rest out with `v` as usual: `v.fieldset`, `v.legend`, `v.table`.
- A path parameter belongs to the action, not to a field: `form.field :invoice_id` raises `ArgumentError` when rendered.
- Attributes go to the element as anywhere else (`form.field :email, autocomplete: "work email"`); `name`, `id`, `type`, `value`, and the like are Punch's and do not compile. A form inside a form, or a control used outside its form, raises `NestingError`.

The control follows the field's type:

| Field | Control |
|---|---|
| `Bool` with a default | checkbox sending `true`; unchecked sends nothing |
| other `Bool`, enums | `select`; an optional one starts with an empty choice |
| `Array` of an enum | `select multiple` |
| `Int32`, `Int64`, `Float64`, primitives over them (IDs, `Money`) | `number`, with `min` and `max` from the primitive's schema |
| `Punch::Upload::Ticket` | a file control and a hidden field for the ticket (`docs/uploads.md`, "The form") |
| `String`, `Time`, other primitives | `text`, with `minlength` and `maxlength` from the schema; `email` for the `email` format, the email keyboard (`inputmode`) for `idn-email`, which browsers' `type=email` would refuse |

`as:` chooses another: `:textarea`, `:password` (never filled in, also not after a refusal), `:hidden`, `:select` with `options:` as value and label pairs (`options: customers.map { |c| {c.id, c.display_name} }`). A required field (neither nilable nor defaulted) is marked `required`, so browsers check it before sending; the server checks again. `Time` fields are text in RFC 3339; locale formats are for showing times, not for parsing them (`docs/translations.md`).

### The page that holds a form

Every form has a page that holds it, so that a refusal has somewhere to be shown: the page named after the Command (`CreatePage` for `Create`, `SendPage` for `Send`), or one that lists it: `@[Punch::Forms(Send, Destroy)]` on `ShowPage`. Without one, `v.form` does not compile; two pages for one Command do not compile either. The holding page is rendered from the Command's path alone, so its path parameters must be the Command's and its other fields optional, checked at compile time. `punch routes` shows it: `POST /billing/invoices/:invoice_id/send  json  Billing::Invoices::Send  (form on Billing::Invoices::ShowPage)`.

A Command whose form a page holds accepts form bodies (`application/x-www-form-urlencoded`) besides JSON, parsed by `Input.from_form` (`docs/input.md`); one without a holding page answers a form body with 415.

### After sending

| The Command | The browser gets |
|---|---|
| succeeds (a result below 400, or `nil`) | `303 See Other` to the page's `redirect(result)`, or by default to the holding page itself at the Command's path parameters |
| refuses the input, or returns a `Punch::Rejection` or a unique violation (`EmailTaken`) | `422` and the holding page again: the form shows what was sent, each field its errors (`aria-invalid`, `aria-describedby`), and a list of every error at its top, linked to the fields. A violation is the error `taken` at its field |
| returns another failure (409 `AlreadySent`, 422 `NoLines`) | that status and the holding page again, the failure's code as the form's error |
| needs a signed-in user | 303 to the sign-in page, or the 401 page when the app has none |

These are Turbo Drive's conventions: Turbo follows a 303 and renders a 4xx answer to a form in place. Without Turbo, browsers do the same. Only the form that was sent shows the values and errors, told apart by Command and path, so a list with a delete button per row marks the right one. Errors show the code's message in the request's locale, with the code in `data-code` (`docs/translations.md`). JSON clients are not affected: the same Command answers JSON as before, and form answers are not in `openapi.json`.

`redirect` takes the result of the Command, overloaded per result type; `nil` keeps the default:

```crystal
def self.redirect(result : Created) : Punch::Href
  ShowPage.href(invoice_id: result.invoice.id)
end

def self.redirect(result : Nil) : Punch::Href # a deleted draft
  IndexPage.href
end
```

## Filter forms

A list narrows with a `GET` form to its own page: the filter, order, or direction it reads from the query string (`docs/queries.md`, "Filter objects"). `v.filter_form(Page, input)` writes `<form method="get">` to the page at the path parameters of *input*, showing what *input* holds, so the form keeps the filter the list was shown with:

```crystal
v.filter_form(IndexPage, @input, class: "filter") do |form|
  form.fields(:filter, Queries::Page::Filter) do |filter|
    filter.field :status, options: Invoice::Status.values.map { |status| {status, Invoices.state(v.locale, status, false)} }
    filter.field :customer_id, as: :hidden
  end
  form.field :limit, as: :hidden
  form.submit t.filter
end
```

- Fields are named as the page's input reads them and as `Page.href` writes them (`filter[status]`), with the same builder and controls as a Command's form. An optional enum is a select with an empty choice, meaning "any".
- Only the fields the form writes are sent. Keep what should survive as hidden fields (`limit`, a customer the list is scoped to); leave out the cursor, so a new filter starts at the first page.
- No CSRF token, no `_method`, no holding page: a `GET` changes nothing, and a filter that does not parse is the page's own 422.
- *input* must be the page's input type; another does not compile. The form is left out, like a link, for a viewer the page's policy does not admit.

## Turbo Frames

`v.frame(id) { ... }` writes a `<turbo-frame>`, a part of the page that links and forms inside it replace on their own. Its DOM ID comes from a typed ID: `Punch.dom_id(invoice_id)` is the public ID, `inv_gLW26G63FZp`, for an ID type with a public form (`docs/core-types.md`), and the entity and rowid, `invoices_42`, for one without; with a prefix, `v.frame(customer.id, "invoices")`, `invoices_cus_9pSnhtaEsBE`. A frame with `src:` loads lazily from a page that has a frame with the same ID; put a link inside for browsers without Turbo:

```crystal
only = Invoices::Queries::Page::Filter.new(customer_id: customer.id)
v.frame(customer.id, "invoices", src: Invoices::IndexPage.href(filter: only), loading: "lazy", target: "_top") do
  v.a "Invoices of #{name}", href: Invoices::IndexPage.href(filter: only)
end
```

Every document loads Turbo (`docs/assets.md`); frames and forms also work as plain HTML without it.

## Turbo Streams

A `Punch::TurboStream` is a list of Turbo Stream actions, changes to parts of a page that is already shown. Each carries a component, rendered as HTML, so the component that is part of a page is sent as it is, without a second template:

```crystal
Punch::TurboStream.build do |stream|
  stream.prepend "invoices", InvoiceRow.new(row)            # first child of #invoices
  stream.replace invoice.id, InvoiceSummary.new(invoice)    # the element #inv_gLW26G63FZp itself
  stream.update invoice.id, InvoiceSummary.new(invoice), morph: true
  stream.remove Punch.dom_id(line.id, "lines")
  stream.refresh                                            # Turbo 8: fetch the page again
end
```

- Actions: `append`, `prepend` (inside the target), `replace` (the target itself), `update` (what the target holds), `before`, `after` (siblings), `remove`, `refresh`. `replace` and `update` take `morph: true`, which changes only what differs and keeps focus and form state.
- A target is a DOM ID: a typed ID, written by `Punch.dom_id` as `v.frame` writes it (`inv_gLW26G63FZp`), `Punch.dom_id(id, "lines")` for a prefixed one, or a string for an element the page names itself (`v.tbody(id: "invoices")`). An empty string or one with whitespace raises. No `targets` (CSS selectors).
- Content renders through an `HTMLView`, so a component may use `raw`. It may start with any element, since it lands wherever its target is (an `li` appended to a list, a `tr` to a `tbody`); below that, nesting is checked as on a page. `v.document` raises: a stream carries parts of a page, so render the component, not the layout.
- Forms and links in the content ask their policies, like on a page, when the stream renders with an authorizer.

### After a form

A page that holds a Command's form can answer it with a stream instead of the redirect, per result type, next to `redirect`:

```crystal
@[Punch::Forms(Create)]
struct IndexPage < Punch::Page
  def self.stream(result : Created) : Punch::TurboStream?
    Punch::TurboStream.build { |stream| stream.prepend "customers", CustomerRow.new(result.customer) }
  end
end
```

- Only a request that names `text/vnd.turbo-stream.html` in `Accept` gets it, as Turbo sends with a form; the answer is 200 with that type and `Vary: Accept`. A browser without Turbo, `*/*`, a result the page has no `stream` for, and a `stream` that returns `nil` get the 303 as before. Refusals are unchanged: the page again, with the errors, which Turbo shows in place.
- The stream renders after the Command, in a read transaction of its own, for the holding page's actor (its forms and links ask their policies). A Command whose answer is stored for an idempotency key renders it inside its transaction instead, so a double submit gets the same stream.
- Only a page that defines `stream` compiles any of this.
- Build the stream from the result. Data the result does not carry belongs in the result, or the page asks for `refresh`.

Specs: `client.submit(action, values, stream: true)` sends Turbo's `Accept`; `response.should have_stream_action(:prepend, "customers", containing: "tr td", text: "Ada")` finds an action by its target and, with `containing:`, an element in its content. `Punch::Spec.render(stream)` renders one without a request.

## Live pages

A page that defines `live` updates while it is open: committed events reach it as Turbo Stream actions over server-sent events. Define one `live` per event type; each takes the event, then what the page's `call` takes, and returns the actions for that viewer, or `nil` when the page shows nothing of it:

```crystal
@[Punch::Authorize(Accounts::Organizations::Current)]
struct IndexPage < Punch::Page
  alias Output = InvoiceList

  def call(input : Input, db : Punch::Reader, actor : Actor) : Output
    # ...
  end

  def live(event : InvoiceSent, input : Input, db : Punch::Reader, actor : Actor) : Punch::TurboStream?
    row = Queries.row(db, event.invoice_id, actor.organization_id) || return
    Punch::TurboStream.build(&.replace(row.id, InvoiceRow.new(row), morph: true))
  end

  def live(event : InvoiceCreated, input : Input, db : Punch::Reader, actor : Actor) : Punch::TurboStream?
    Punch::TurboStream.build(&.refresh) if event.organization_id == actor.organization_id
  end
end
```

- **The stream is the page's own URL.** A live page's HTML ends its body with `<turbo-stream-source src="/billing/invoices?filter[q]=x&_live=…">`; Turbo opens it with `EventSource`, which asks for `text/event-stream`, and closes it when a visit replaces the page. Nothing else names a stream: no channel names, no signed tokens. `punch routes` shows `live` among the page's surfaces.
- **Every event is decided for each viewer.** When a stream opens, the page's authentication and policy run as for the page (a refusal answers 401, 403, or 404, and `EventSource` gives up). For every event the page takes, they run again in a read transaction of the stream's own, then `live`; forms and links in the actions ask their policies for that viewer, in their locale. A viewer who lost access (signed out, session expired, removed from the organization) gets no more events: the stream ends. While no event comes, the check runs again at each keepalive, so such a stream ends within 15 seconds. The policy is the page's: whether the record an event names belongs to the viewer (their organization, their own) is for `live` to check before it renders a row; `refresh` is safe, since the page renders again under its policy. An open page does not keep its session alive; only requests do.
- **Which events.** `live`'s first parameter is an event, an abstract event, or a marker module events include; the event must be published by a Command (`Punch::Events`) and commit. Delivery is after commit, from the same place as after-commit subscribers; only events some live page takes reach the hub.
- **Nothing is missed between the page and its stream.** `_live` is where the hub stood before the page's read transaction began; the stream first replays the events after it, then follows. A reconnecting browser sends the last event's ID (`Last-Event-ID`) and catches up the same way. A stream replays at most 64 events when it opens (`InProcess::MAX_REPLAY`); further behind, it refreshes the page. When the hub no longer holds those events (it keeps the last 1024), when the position is from another process (after a deploy), or when a stream falls 64 events behind, the stream sends `refresh` and Turbo fetches the page. An event may thus arrive twice (committed before the page's snapshot, published after the position was taken); `replace`, `update`, `remove`, and `refresh` are safe to repeat, and Turbo removes an element with the same ID before an `append` or `prepend`.
- **Keep `live` cheap.** It runs once per open stream that takes the event, each in its own read transaction: a hundred viewers of a list cost a hundred renders per change. Return early on what the event says (`event.organization_id`, the page's input) before reading. For changes too wide to describe, return `refresh`; with `v.document(..., morph: true)` in the page's layout, Turbo morphs the page instead of replacing its body, and keeps the scroll position (`turbo-refresh-method` and `turbo-refresh-scroll` in the head) and what the viewer is typing.
- **A failing `live`** (an exception) skips that event for that stream: logged, reported as a failed trace `live <path>`, and the stream goes on.

### Limits

- **One process.** The hub is in-process (`Punch::Live::InProcess`, behind the `Punch::Live::Hub` interface). Events committed in another process, a separate `punch jobs` among them, do not reach this process's streams. `serve` runs jobs in its own process unless `jobs` is off.
- **Deploys.** On shutdown, once the listener has closed, every stream closes (`Server#on_drain`); browsers reconnect, reach the new process, and refresh, since its positions start anew.
- **Connections.** Each stream holds a connection and a fiber. `Punch::Live.max_streams` caps them per process: 1000, or three quarters of the server's `max_connections` if that is fewer, so other requests still get through (`docs/http.md`, "Connections"). `Punch::Live.max_streams_per_viewer` (16) caps one signed-in user's streams, or for a page without an actor one client address's. One more is answered 503 with `Retry-After`, and that page stays without live updates until it is loaded again. Browsers allow six HTTP/1.1 connections per host, so a reverse proxy speaking HTTP/2 to browsers is needed for many tabs. Idle streams send a comment every 15 seconds (`Punch::Live.keepalive`), so proxies keep them and a gone client is noticed; responses carry `Cache-Control: no-store` and `X-Accel-Buffering: no`.
- A page that takes `Punch::Auth::Reveal` cannot be live.

The reference app's invoice list is a worked example (`Billing::Invoices::IndexPage`): one `live` per event, the page query's by-key variant (`Queries.page_by_key`, `docs/queries.md`, "Pages"), which has the list's own clauses, to decide whether a changed invoice still matches the viewer's filter, `replace` or `remove` where that is exact, and `refresh` where an invoice may have come into the list.

Specs: `live = client.live(IndexPage.href)` opens the stream in a fiber; `live.next` waits for the next message's actions (`have_stream_action` applies), `live.next?` returns `nil` when none comes, `live.ended?` tells whether the server ended it, `live.last_event_id` is what a browser would send back, and `client.live(href, last_event_id: …)` reconnects with it. `live.close` ends it.

## Pages agents read

A page that agents may read declares it, and then answers `Accept: text/markdown` with markdown rendered from the same components:

```crystal
@[Punch::AgentReadable]
struct ShowPage < Punch::Page
  ...
end
```

```markdown
# Invoice INV-000001

Customer: [Ada Lovelace](/billing/customers/cus_9pSnhtaEsBE). Status: **draft**

| Description | Amount |
|---|---|
| Consulting | 300.00 EUR |
```

- **Opt-in per page.** Nothing reaches the markdown surface without `@[Punch::AgentReadable]`. A page without it answers HTML whatever the client asks for (a server may ignore `Accept`); the annotation on anything but a page does not compile.
- **Negotiation.** `Accept` with q-values picks between HTML and markdown, and JSON where a Query shares the path: a browser gets HTML, an agent sending `text/markdown` gets markdown, and `*/*` gets the default (JSON on a shared path, else HTML). The answer carries `Vary: Accept` and `Content-Type: text/markdown; charset=utf-8; variant=GFM`.
- **The `.md` URL.** Not every agent sends `Accept`, so the page's path with `.md` (`/billing/invoices/inv_gLW26G63FZp.md`, `/index.md` for `/`, the query kept) answers markdown whatever `Accept` says, without `Vary`. The `.md` URL of anything that is not an agent-readable page is a 404 (in markdown); a GET path parameter therefore cannot end in `.md`. The request goes on without the suffix: traces, forms, and idempotency keys see the page's path.
- **Links stay on markdown.** In markdown, a link to an agent-readable page goes to its `.md` URL (`Href#markdown_url`); a link to any other page keeps its path, where it answers HTML. The HTML of an agent-readable page names its markdown in the head: `<link rel="alternate" type="text/markdown" href="/billing/invoices/inv_gLW26G63FZp.md">`.
- **What it looks like.** GitHub Flavored Markdown: headings, paragraphs, `**strong**`, `*em*`, `~~s~~`, code spans, links to the page's path, lists (nested by indentation), quotes, fenced `pre`, and tables (the head's first row is the header, or the first row). Containers (`div`, `main`, `section`, frames) are transparent; a definition list is a list of `term: description`; an image is its alt text. Chrome and the document's head are left out; forms become action blocks (below). A frame that loads lazily (`src:`) is empty in markdown, so give it a link inside.
- **Escaping.** Text stays text: no link, emphasis, HTML, or block structure can come from it, checked against cmark-gfm with hostile strings (`spec/view/markdown_spec.cr`). A bare URL in text may become a visible link in a GFM renderer, whose text is its address; nothing else becomes markup.
- **Checked at compile time.** An agent-readable page renders through a plain `Punch::View`, which has no `raw`. A component on it that writes raw HTML outside chrome fails with `undefined method 'raw' for Punch::View` at the line that does; one that takes `v : Punch::HTMLView` fails with a message naming it. Move the markup into a chrome block, or write it with elements. People-only pages are not affected: `raw` keeps working there.
- **Problems** of an agent-readable page (404, 422 with its field errors, 403) are markdown for an agent. One without a session or token gets the 401, never the redirect to the sign-in page: agents sign in with a token.
- **Telemetry:** `punch.surface` is `markdown`, also for an action an agent sends.

### Discovery: `/llms.txt`

An agent given only the base URL starts at `/llms.txt` ([llmstxt.org](https://llmstxt.org)). Punch writes it from the route table, listing the agent-readable pages marked as entry points:

```crystal
@[Punch::AgentReadable(entry: true)]
struct IndexPage < Punch::Page
```

```markdown
# Invoicing

> Invoices and customers of the organization you work in.

Each page listed below is markdown at its `.md` address; … (how to read, sign in with a token, act, retry with the same idempotency key, and wait out a 429)

## Pages

- [Invoices](/billing/invoices.md): the organization's invoices, filtered by status or text

## Optional

- [OpenAPI](/openapi.json): the JSON API's contract, for programs
```

- **Entry points** are pages an agent opens from their path alone: an entry point with a path parameter or a required field does not compile, nor does one that is `@[Punch::Unlisted]`. Other agent-readable pages are reached by links.
- **The app's text** comes from its locale files, in the request's language (`Vary: Accept-Language` when it chose): `llms.title`, `llms.summary`, and per entry point `llms.pages.<operation id>.title` and `.description` (`llms.pages.billing.invoices.index_page.title`). Without a title, the page's operation ID humanized. Punch's paragraphs are `punch.llms.*`, the retention of idempotency keys filled in.
- **Served** as `text/plain; charset=utf-8`, to anyone: it lists paths, as `openapi.json` does, and the pages answer by their policies. An app without entry points has no `/llms.txt` (404). `## Optional` lists `/openapi.json` where the app serves it.
- **`punch routes`** shows each route's surfaces (`json`, `html`, `markdown`; a Command whose form a page holds answers all three) and marks entry points.

### Action blocks

Markdown has no forms, so each form on an agent-readable page becomes an action block, collected under `## Actions` at the end of the page. Nothing is declared: the block is generated from the form as the page renders it.

```markdown
## Actions

Send an action to its address with its fields as a form body (`application/x-www-form-urlencoded`), or as query parameters for a `GET`. Success answers `303 See Other` with the next page in `Location`; a refusal answers with this page again, the errors in the action.

### Send invoice

`POST /billing/invoices/inv_gLW26G63FZp/send.md` · operation `billing.invoices.send` · not idempotent · at most 30 per 1 h per user

- `_idempotency_key` = `kFdIQHbhM25-F021zZStgw3z` (send it as it is, also when you retry)
- `recipient` (Recipient): email address, required, at most 254 characters, now `ada@example.org`
  Invoices go to this address.
- `priority` (Priority): one of `normal` (Normal), `urgent` (Urgent), required
- `copy_to_me` (Copy to me): `true` or leave it out
- `send_at` (Send at): date and time (RFC 3339), optional
- `copies` = `2` (send it as it is)

### Delete invoice 42

`DELETE /billing/invoices/inv_gLW26G63FZp.md` · operation `billing.invoices.destroy` · idempotent · destructive
```

- **Title:** the form's `aria: {label: …}`, else its submit button's text, else the operation's name. Give forms that repeat on a page (a delete button per row) an `aria` label that says which.
- **Where it goes:** the Command's real method and path (no `?_method=`) with the `.md` suffix, so the answer is markdown without `Accept`, and the operation ID as in OpenAPI. A filter form (`v.filter_form`) is a `GET` to its page (its `.md` URL when the page is agent-readable), its fields in the query string.
- **Safety hints** from the method: `GET` is safe; `PUT` and `DELETE` are idempotent; `DELETE` is destructive; `POST` and `PATCH` are not idempotent.
- **Rate limits** of the operation, each as `at most N per period per key` (`@[Punch::RateLimit]`).
- **Idempotency key:** a form that carries a key (`idempotent: true`, or a Command that requires one) shows it as a field to send as it is, also on a retry. A Command that takes an optional key and whose form carries none says it takes an `Idempotency-Key` header.
- **Fields:** exactly the controls the form writes, in order, by the names it sends them under (`lines[0][description]`): the label, what it takes (text, email address, whole number, date and time, one of the select's choices as `value` (label), a checkbox's value or nothing), required or optional, lengths and ranges, the hint, and the value the form holds now. Hidden fields are values to send as they are; empty ones are left out (empty is absent, `docs/input.md`). Passwords are never shown.
- **Shown only when the form is:** the state the page is in (no Send for an invoice already sent) and the viewer's policy (`docs/authorization.md`) decide, as for HTML. An agent's token can do what its user can do.
- **Language:** the phrases follow the reader's locale (`punch.actions.*` in Punch's locale files, overridable by the app); field names, values, operation IDs, and codes never change.
- **Escaping:** labels, hints, choices, and titles are escaped text; values are code spans. The hostile strings of `spec/view/markdown_spec.cr` run through action blocks too.

**An agent acts** by sending the fields as a form body to the block's address, with its token, as a browser sends the form. The same path without `.md` answers the same way to `Accept: text/markdown`:

| Answer | When |
|---|---|
| `303 See Other` to the next page (`Page.redirect`), at its `.md` URL when it is agent-readable | the Command succeeded |
| The holding page again, as markdown, with the refusal's status | a rejection (422), a failure result (409, …), or a refusal by policy (403): field errors under their fields, others at the top of the action |
| The page with the problems at the top of `## Actions` | the refused form is no longer on the page, such as a Send that failed because the invoice was sent in between |
| A problem in markdown with its field errors | the page holding the form is not agent-readable |

A JSON body still gets the JSON contract (`docs/openapi.md`). A retry with the same idempotency key gets the first answer replayed.

Not built: inputs of one of several shapes; an `@[Punch::Destructive]` annotation for a `POST` that destroys; a textarea's line breaks in "now" (shown on one line).

## Specs

```crystal
response = AccountsSpec.client.visit(Invoices::ShowPage.href(invoice_id: id))
response.status.should eq(HTTP::Status::OK)
response.should have_element("main > h1", text: "Invoice INV-000001")
response.should have_element("table.lines tbody tr", count: 2)
response.should_not have_element("nav")

Punch::Spec.render(LinesTable.new(detail)).should have_element("td", text: "125.00 EUR")
```

Pages agents read, and their actions, as an agent uses them:

```crystal
agent = Punch::Spec.bearer(Punch::Spec.api_token(user.id))
page = client.read(Invoices::ShowPage.href(invoice_id: id), headers: agent)
page.should have_action("Send invoice", operation: "billing.invoices.send")
answer = client.act(page, "Send invoice", {"recipient" => "ada@example.org"}, headers: agent)
answer.should redirect_to(Invoices::ShowPage.href(invoice_id: id).markdown_url)
client.get("/llms.txt").body.should contain("(/billing/invoices.md)")
Punch::Spec.actions(page.body) # => [ActionBlock(title, method, path, operation_id, fields, fixed, text), ...]
```

`Punch::Spec.actions` reads the blocks as an agent should: only under the page's last `##` heading, and never inside a code block, so text a page shows verbatim cannot add one. `client.act` reads the block, sends its fixed fields (hidden values, the idempotency key) with the given ones, and fails the example for a field the block does not name: an agent could not have known it.

- `client.visit(href)` asks as a browser does (`Accept: text/html,…`). HTML responses are not checked against `openapi.json`. A filter form's request is a link: `client.visit(IndexPage.href(filter: Queries::Page::Filter.new(status: :draft)))`; for JSON, `client.get(Index.path, query: {filter: {status: "draft"}})` writes the brackets.
- `client.submit(Command.action(...), {field: value})` sends a form as a browser does, with values checked like `values:`; `form: {"email" => "not an address"}` sends anything. `response.should redirect_to(ShowPage.href(...))` checks the 303, `have_field_error("lines[0][quantity]", "out_of_range")` a field's error.
- `have_element(selector, text:, count:)` works on a response or an HTML string. `text` is compared with whitespace collapsed, or matched by a `Regex`. Selectors: type, `*`, `#id`, `.class`, `[attr]`, `[attr=value]`, `[attr^=value]`, `[attr*=value]`, descendant and `>` combinators, and lists.
- `response.html.find(selector)` and `.text(selector)` for anything else, and `Punch::Spec.render(component)` for a component alone. Parsing uses libxml2, linked into spec binaries only.
- `client.read(href)` asks as an agent does (`Accept: text/markdown`); `response.body` is the markdown. `client.get(href.markdown_url)` asks by the `.md` URL. `Punch::Spec.markdown(component)` renders a component alone, and does not compile for one that writes raw HTML.

## Telemetry

The request event records `punch.surface` (`html`, `markdown`, `live`, or `json`; `html` for a form sent to a Command), so traffic to pages and to the API can be told apart; a live page's stream is a request whose event ends once the stream has started, so its duration is the connect, not how long the page stayed open. A page's rendering is a `render` span with `punch.view`, the component's type. A refused form keeps the refusal as `punch.outcome` (`invalid_input`, `already_sent`), and a unique violation its constraint as `punch.violation`, while its page is shown again.
