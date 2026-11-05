# Application structure

Learn it in: [Application Structure](guides/application-structure.md).

Where code lives in a Punch app, and why. A type's full name decides its file, and the file's place decides its route, its `operationId`, its permission ID, and when it is required. So a name seen anywhere (a trace, a route, an error, the ops console) leads to one file without a search, and a new thing has one place.

## Slices, namespaces, entities

```text
app/
  setup.cr  actor.cr  credentials.cr      the app (MyApp::…)
  components/layout.cr
  billing.cr                              outline of the slice
  billing/                                a slice
    events.cr
    invoices.cr                           outline of the entity
    invoices/                             an entity: it owns tables
      columns.cr  types.cr  queries.sql
      invoice.cr  store.cr  results.cr  policies.cr
      operations/  pages/  jobs/  mail/  subscribers/
    payments.cr
    payments/                             a namespace without tables
      provider.cr
```

- **A slice** is a directory directly under `app/`, a bounded part of the domain (`billing`, `accounts`). Another slice uses its data only through its operations, its policies, or a function it offers for the purpose (`Accounts::Mailing.organization_locale`), never its `Queries`, `Table`, or `Store`; `Punch/SliceBoundary` reports those. Its IDs, events, and the records its operations answer with pass between slices as values.
- **A namespace is a directory,** at any depth: `Accounts::Organizations::Members` is `app/accounts/organizations/members/`. A file's outermost module is its directory's namespace; files directly in `app/` belong to the app's module. Directories of a kind (`operations/`, `pages/`, `jobs/`, `mail/`, `subscribers/`, `components/`) add no namespace: `app/billing/invoices/operations/send.cr` holds `Billing::Invoices::Send`.
- **Nest only what belongs to its parent.** A namespace goes under another when its rows belong to one of the other's (its table has a foreign key to the parent as owner), because the route says so too: `/accounts/organizations/{organization_id}/members`. A grouping that is not ownership stays a sibling in the slice.
- **An entity is a namespace that owns tables:** it maps them in its `columns.cr`, and each table has one owner. Everything of the entity is in its directory, so it is one directory plus its outline.
- **A use case goes where it writes.** An operation lives with the entity whose state it changes; a Query with the entity it reads. One that changes several gets a namespace without tables beside them (`app/accounts/sign_up/`). No operations directly in a slice.
- **One namespace per entity.** The entity's types, its model included, are in its namespace: `Billing::Invoices::Invoice`, with `Invoice::Draft` and `Invoice::Sent`, not a second module `Billing::Invoice`.
- **No table, same rules.** A concept without a table (a webhook provider, a set of roles, a value type) is a namespace with an outline, a file named after its type, or a line in its owner's `types.cr`.
- **Every namespace directory has an outline:** the file beside it, named like it (`app/billing/invoices.cr`), a documented module saying what the concept means, is for, and guarantees (`docs/models.md`).

`punch generate entity billing/plans` and `punch generate namespace accounts/invitations` write these files for a new entity or namespace: the outlines, and for an entity `types.cr`, `columns.cr`, and `queries.sql` (`docs/tooling.md`).

## File kinds

Every Crystal file under `app/` is of one kind, by its name or its directory. `punch requires:generate` writes `app/requires.gen.cr`, which requires every file in this order; within a kind, shallower files come first (a slice's `types.cr` before an entity's), then by path. The app's library file requires Punch and that file, nothing else:

```crystal
# src/invoicing.cr
require "punch"
require "../app/requires.gen"
```

| # | Kind | Files |
|---|---|---|
| 1 | Translations | `translations.gen.cr`, from `punch i18n:generate` |
| 2 | Types | `types.cr`: IDs and domain primitives of the namespace |
| 3 | Events | `events.cr`: the namespace's domain events |
| 4 | Outlines | `X.cr` beside the directory `X/` |
| 5 | Columns | `columns.cr`: the column types of the entity's tables (`docs/queries.md`) |
| 6 | Records | `records.gen.cr`, from `punch db:generate`, beside its `columns.cr` |
| 7 | Named | a file named after a type it holds: `invoice.cr` (`Invoice`), `actor.cr`, `credentials.cr`, `sharing.cr`, `provider.cr` |
| 8 | Setup | `app/setup.cr`: every `Punch.*` declaration (`assets`, `translations`, `credentials`, `migrations`) and `Punch::*.config =`, the console's `mount`; after the types it names (Punch/SetupFile) |
| 9 | Record | `record.cr`: behaviour of a generated record (`docs/models.md`) |
| 10 | Queries | `queries.gen.cr`, from `punch db:generate`, beside its `queries.sql` |
| 11 | Store | `store.cr` |
| 12 | Shared | `inputs.cr`, `results.cr`, `policies.cr`: what several operations of the namespace share |
| 13 | Operations | `operations/`, `jobs/`, `mail/`, `subscribers/`: one file per type, named after it, with the types only it uses |
| 14 | Components | `components.cr` (shared in a namespace) and `components/` (one file per component; `app/components/` for the whole app, layouts included) |
| 15 | Pages | `pages/`: one file per page, with the components only it renders |
| 16 | Roles | `roles.cr`: roles name operations, so they come last |

A file that fits no kind is refused, with these kinds. Adding a file needs no require: `punch typecheck`, `punch dev`, and `punch check` (step `requires`) keep the require file current or report it stale. Never edit it.

One file per type that a tool shows by name (operations, pages, jobs, mails, subscribers): traces, routes, `punch jobs`, `punch events`, and the ops console show those names, and the name gives the file.

## Derived names

The namespace is public: `Billing::Invoices::Send` is `POST /billing/invoices/{invoice_id}/send`, `operationId` and permission `billing.invoices.send`, and its OpenAPI tag is the slice. With the reserved names (`Index`, `Show`, `Create`, `Update`, `Destroy`), placing a use case where it writes turns verbs into resources: sign-in is `Accounts::Sessions::Create`, `POST /accounts/sessions`. Naming a namespace is naming that API.

## Specs

Specs mirror `app/`: `spec/billing/invoices/send_spec.cr` for `app/billing/invoices/operations/send.cr`, `show_page_spec.cr` for a page, `invoice_spec.cr` for the model. Journeys across slices or namespaces go in `spec/journeys/`. Factories per slice in `spec/support/` (`spec/support/billing.cr`, where Ameba expects helpers), required by `spec/spec_helper.cr`.
