# Reference app: invoicing

Punch's reference app: a small invoicing app that uses every part of Punch, as the worked example the docs quote. Users sign up and sign in by password, mailed link, or API token, with an optional second step. Customers and invoices belong to organizations, and what a user may do in one follows from their role there. Sending an invoice mails it to the customer, and a payment provider's webhook marks it paid. The invoice list is a search screen that stays live in the browser, and agents read the same pages as markdown, starting at `/llms.txt`, and act through their action blocks. The accounts slice, the home page, and the deploy recipes are rendered from the template of `punch new`.

```sh
shards install
punch check                                   # everything CI runs
punch creds:init && punch keys:rotate          # credentials file, key, and a key ring (once)
echo "Example GmbH" | punch creds:set issuer.name
PUNCH_STORAGE=/tmp/invoicing punch dev        # migrate, build, serve on :3000, rebuild on change
bench/run.sh 4 64 10                          # latency under mixed read and write load
```

`PUNCH_STORAGE` must be on local disk.

`AGENTS.md` is the guide for working on the app, for people and coding agents: the loop, where things go, which construct to use, and what an error means.

Open `http://localhost:3000/billing/invoices` and create an account. For the API, make a token for that user:

```sh
bin/invoicing tokens:create --user 1 --name dev      # prints inv_…, once
curl -H "Authorization: Bearer inv_…" localhost:3000/accounts/users/me
```

The app refuses to start without its credentials (`app/credentials.cr`): the key ring that signs invoice links, the issuer shown on invoices, and how mail leaves the app. They live in an encrypted file, as above, or in variables (`SECRET_KEY_BASE`, `ISSUER__NAME`, `MAIL__DELIVERY=capture`, `MAIL__FROM`). With `capture`, mail is not sent but shown in the ops console at `/_punch/mail`; links in it point to `PUNCH_PUBLIC_URL`. The key, `config/credentials/development.key`, stays out of Git; deployments set `PUNCH_MASTER_KEY` and `PUNCH_ENV` instead. `bin/invoicing creds:check` shows where each value came from, `punch keys` the ring.

## What it shows

| | Where |
|---|---|
| **An outline per namespace**: what it means and is for among the others, in plain words, in the documented module beside the directory (entities, flows, and the slices), with at most the constants the domain names (`Punch/NamespaceFile`) | `app/billing.cr`, `app/billing/invoices.cr`, `app/accounts.cr`, `app/accounts/sessions.cr`, `app/accounts/organizations.cr`, … |
| Schema as migrations, `db/schema.sql` written from them | `db/migrations/`, `db/schema.sql` |
| Columns mapped to domain types once, by the entity that owns the table; each entity's IDs and primitives in its own `types.cr` | `app/billing/invoices/columns.cr`, `app/billing/invoices/types.cr`, `app/accounts/users/types.cr` |
| Named SQL, generated typed methods and records | `app/billing/*/queries.sql`, `queries.gen.cr` and `records.gen.cr` beside their sources |
| No hand-kept requires: every file under `app/` is of a kind, and the generated require file loads them in the order of their kind (`lib/punch/docs/structure.md`) | `app/requires.gen.cr`, `src/invoicing.cr` |
| **Tier 1 model**: behaviour on the generated record | `app/billing/customers/record.cr` |
| **Tier 2 model**: one immutable type per state, transitions as methods | `app/billing/invoices/invoice.cr` |
| A store that turns rows into states and back | `app/billing/invoices/store.cr` |
| A behaviour module shared by a state type and list rows (`overdue?`) | `Invoice::Due` in `invoice.cr`, `-- include` in `invoices/queries.sql` |
| Queries and Commands, one per file in each slice's `operations/`, results with statuses; shared results and policies beside them (`results.cr`, `policies.cr`) | `app/billing/*/operations/`, `app/billing/*/results.cr` |
| A collated column (`COLLATE de`), changed by a table rebuild; prefix search with `LIKE` beyond ASCII | `db/migrations/20261009090000_sort_customer_names.sql`, `Customers::Search` |
| Contract-checked endpoint specs, a store round trip; specs mirror `app/` (`spec/<slice>/<namespace>/<file>_spec.cr`), journeys across namespaces in `spec/journeys/`, factories per slice | `spec/billing/invoices/`, `spec/journeys/`, `spec/support/` |
| Credentials declared as a type, checked at boot, from the environment or the encrypted file; `Punch::Spec.credentials` in specs | `app/credentials.cr`, `spec/spec_helper.cr` |
| A signed, expiring link from the key ring, valid through a key rotation | `app/billing/invoices/sharing.cr`, `Invoices::Link` and `Shared`, `spec/billing/invoices/sharing_spec.cr` |
| An actor loaded in the operation's transaction; operations that need it, 401 without it; one public operation | `app/actor.cr`, `app/billing/*/operations/`, `Invoices::Shared` |
| The accounts slice, the home page where sign-ins land (`Home::IndexPage`, `GET /`), the systemd recipe, and `AGENTS.md`, rendered from Punch's template as `punch new` writes them (`scripts/sync-reference.sh`); the texts of the accounts slice in `config/locales/accounts/` | `app/accounts/`, `app/home/`, `deploy/` |
| Users without secrets; Punch's session and token tables in the app's migration | `db/migrations/20261009120000_create_users_and_sessions.sql` |
| Signed-in specs (`sign_in`, `api_token`), cross-site Commands refused | `spec/spec_helper.cr`, `spec/accounts/users/me_spec.cr`, `spec/journeys/api_access_spec.cr` |
| A cached aggregate (memory in front of `cache.db`) that is correct with the cache off, forgotten after commit by `@[Punch::Subscriber::Forget]`; a versioned result answered with 304 | `Customers::STATEMENTS`, `Customers::ForgetStatement`, `Customers::Statement`, `spec/billing/customers/statement_spec.cr` |
| Pages for people beside the JSON API, on the same paths; a layout with navigation as chrome; components reused by two pages; a public page behind the signed link | `app/components/layout.cr`, `app/billing/invoices/pages/`, `app/billing/invoices/components.cr`, `spec/billing/invoices/show_page_spec.cr` |
| Forms bound to the API's Commands: a refused form shown again with its errors, a failure as the form's error, a 303 after success; rows of lines with empty rows to fill in; buttons for state changes on the page that shows the state | `app/billing/customers/pages/`, `app/billing/invoices/pages/`, `spec/billing/customers/create_page_spec.cr`, `spec/billing/invoices/create_page_spec.cr` |
| A Turbo Frame loaded lazily from another page, with a link for browsers without Turbo | `Customers::EditView`, `Invoices::ListView` |
| Assets embedded with fingerprinted URLs: a stylesheet that refers to an image, an image in the layout, Turbo loaded through the import map, a confirmation before deleting a draft (`data-turbo-confirm`) | `app/setup.cr`, `app/assets/`, `app/components/layout.cr`, `spec/components/layout_spec.cr` |
| A policy or the public marker on every operation; a policy that hides other users' sessions (404), with its grant in the Command; forms and links that ask the policies before rendering | `Accounts::Sessions::Own`, `app/**/policies.cr`, `spec/accounts/sessions/destroy_spec.cr` |
| **Organizations and roles**: customers and invoices belong to an organization; three roles in code that include each other (member reads, editor also writes and sends, administrator also manages members), held per organization, optionally until a date; policies that ask the roles about the record's organization (403 to a member whose role does not permit it, with the button gone; 404 to anyone without a role there); the organization a session or API token works in, switched by a Command, scoping lists and new records; members given a role by verified address, one role each, the last administrator kept, `Punch::Roles` events as the audit trail; a body field (`customer_id`) checked by the Command because no policy sees it; an organization on invoices kept equal to its customer's by a composite foreign key; addresses unique per organization; existing users moved into organizations of their own by the migration | `app/accounts/roles.cr`, `app/accounts/organizations/`, `Customers::ByRole`, `Invoices::ByRole`, `Invoices::Create`, `db/migrations/20261013123441_create_organizations_and_roles.sql`, `spec/journeys/tenancy_spec.cr`, `spec/accounts/roles_spec.cr` |
| **An invoice search screen**: the invoice list finds an invoice number by its start or a customer by part of the name, the typed text escaped so `%` and `_` match themselves, together with the state filter and pages | `Invoices::Index`, `Invoices::IndexPage`, `app/billing/invoices/queries.sql`, `spec/billing/invoices/index_spec.cr` |
| **The auth slice with mail**: addresses verified by a mailed link, password reset and sign-in by mail through one-time links (the page only looks, its button uses the token), changing the password with the current one (other sessions end), adding and removing addresses behind a recent sign-in and the keep-one-way-to-sign-in rule, Punch's auth events, notice mails | `app/accounts/emails/`, `passwords/`, `password_resets/`, `magic_links/`, `mail/`, `mailing.cr`, `links.cr`, `spec/accounts/emails/`, `spec/journeys/password_reset_spec.cr` |
| **Two-step sign-in**: an authenticator app set up from the account page (key, `otpauth:` link, recovery codes shown once, confirmed with the first code), the second step after the password or a mailed link, recovery codes, and re-authentication (`Punch::RecentlyAuthenticated`; with the app's code once the user has one) before changing addresses or the second factor | `app/accounts/second_factor/`, `app/accounts/sessions/pages/reauthenticate_page.cr`, `spec/accounts/second_factor/` |
| A browser without a session sent to the sign-in page; the whole way from sign-up to a sent invoice and out again | `Punch::Pages.sign_in` in `app/setup.cr`, `spec/journeys/sign_up_to_sent_invoice_spec.cr` |
| **A domain event:** sending an invoice publishes `InvoiceSent`; an after-commit subscriber in the customers slice forgets the customer's cached statement, so it is current at once. `punch events` prints who publishes and who listens | `app/billing/events.cr`, `Invoices::Send`, `app/billing/customers/subscribers/forget_statement.cr`, `spec/billing/customers/forget_statement_spec.cr` |
| **Event-driven follow-up work:** `InvoiceSent` has an after-commit subscriber (the statement above) and a deferred one, `Invoices::MailInvoice`, which runs as a job through the outbox and mails the invoice with a signed link (`InvoiceMail`) in the customer's language, else the organization's. One subscriber hears two events through a module both include (`BalanceChanged`) | `app/billing/events.cr`, `app/billing/invoices/mail/invoice_mail.cr`, `app/billing/invoices/subscribers/mail_invoice.cr`, `spec/billing/invoices/mail_invoice_spec.cr` |
| **Inbound webhooks**: a payment provider (`Payments::Provider`, Standard Webhooks signatures) whose deliveries Punch verifies, stores, and answers with 204, then processes in a job: `parse` into a typed event, `process` marks the invoice paid in one transaction with the invocation's move to `processed`, once per delivery ID. A bad signature is 401 and stores nothing; a wrong amount or an unknown invoice ends the invocation `failed` and publishes `Punch::Webhook::ProcessingFailed`; other events end `ignored`. Its secret is the optional credential `payments.webhook_secret` (`PAYMENTS__WEBHOOK_SECRET`), with `previous_webhook_secret` during a rotation; without it the endpoint answers 404. Punch's `punch_webhooks` table is in the app's migrations | `app/billing/payments/provider.cr`, `app/credentials.cr`, `db/migrations/20261012132603_create_webhooks.sql`, `spec/billing/payments/provider_spec.cr` |
| **A new state without a new status:** `Paid` is a sent invoice with a row in `invoice_payments`, so the previous release still reads every invoice; the status enum in the API gained `paid`, a breaking change, so the version went from 0.1.0 to 0.2.0 | `db/migrations/20261012090000_create_invoice_payments.sql`, `Invoices::Store`, `shard.yml` |
| **Idempotency keys**: sending an invoice requires `Idempotency-Key`, so a client that lost the answer retries with the same key, gets the first answer, and the customer gets one mail; that made the header a required parameter, a breaking change, so the version went from 0.2.0 to 0.3.0. The forms that add customers and invoices carry a generated key, so a double submit adds one. Punch's key table is in the app's migrations | `Invoices::Send`, `app/billing/*/pages/create_page.cr`, `db/migrations/20261012131158_create_idempotency_keys.sql`, `spec/billing/invoices/send_spec.cr`, `spec/billing/customers/create_page_spec.cr` |
| **The ops console** at `/_punch`, mounted with the app's actor and a policy: users holding the global role `Accounts::Roles::Operator` (`bin/invoicing roles:assign Accounts::Roles::Operator --email ADDRESS`), 404 for anyone else; an "Ops" link only operators see. Errors, job runs, and committed events are recorded in `ops.db` | `app/setup.cr`, `app/accounts/policies.cr`, `app/components/layout.cr`, `spec/journeys/ops_console_spec.cr` |
| **Pages agents read**: the invoice list and an invoice's page as markdown (`Accept: text/markdown` or the `.md` URL), with their forms as action blocks (the idempotency key and the rate limit stated); `/llms.txt` naming the list as the entry point; API tokens for agents managed on a page, created only after a recent sign-in | `@[Punch::AgentReadable]` on `Invoices::IndexPage` and `ShowPage`, `app/accounts/tokens/`, `spec/journeys/agents_spec.cr`, `spec/accounts/tokens/` |
| **Live pages**: the invoice list open in a browser follows the organization's invoices over server-sent events. Each change is an event (`InvoiceDrafted`, `DraftRevised`, `InvoiceSent`, `InvoicePaid`, `DraftDeleted`), one `live` per event decides for each viewer: the row replaced (morphed) where it is shown, removed where it no longer matches the filter, and the page refreshed (morphed, scroll kept) where an invoice may have come into the list; nothing for another organization. Whether a changed invoice still matches is the list's own clauses on one ID (`Queries.listed`). An invoice's page refreshes when that invoice changes (`InvoiceChanged`). A payment processed by the webhook job shows too, since `serve` runs the jobs; a separate `jobs` process would not reach the streams (`lib/punch/docs/views.md`, "Limits") | `Invoices::IndexPage#live`, `ShowPage#live`, `app/billing/events.cr`, `app/billing/invoices/queries.sql`, `spec/billing/invoices/index_page_spec.cr` |
| Matchers for events and jobs: `->{ … }.should publish(InvoiceSent, …)`, `.should enqueue(Remind, …)` | `spec/billing/customers/forget_statement_spec.cr`, `spec/billing/invoices/send_spec.cr` |
| The committed OpenAPI document, with the security schemes | `openapi.json` |
| The committed payload lock: the shape of every stored job payload, which `punch check` holds compatible across deploys (`punch jobs:lock`) | `payloads.lock.json` |

## The domain

Each namespace's outline, the file beside its directory, is the place to start: `app/billing.cr`, `app/accounts.cr`, `app/billing/customers.cr`, `app/billing/invoices.cr`, `app/accounts/organizations.cr`, … (`lib/punch/docs/models.md`, "The outline of an entity").

- Customers, and the invoices to them, **belong to an organization**. Users belong to organizations through roles (`Accounts::Roles`): a member reads, an editor also writes and sends, an administrator also decides who belongs. Someone without a role there does not see them: another organization's customer or invoice is not found, in lists and by ID. A session or API token works in one organization at a time, the one it chose last or else the user's first; lists show that one's records and new ones go into it. An invoice carries its customer's organization, so an organization's invoices are one index range. Signing up starts an organization of one's own.
- A **customer** is reference data: created, shown, edited. Email addresses are unique per organization. Its one rule, the name invoices are addressed to (`display_name`), is a method on the generated record: tier 1.
- An **invoice** has a lifecycle: a `Draft` can be revised, deleted, or sent; a `Sent` invoice is final, numbered, and due 14 days after sending, and mailed to its customer; it becomes `Paid` when a payment of its total arrives, and a paid invoice is never overdue. Its state decides which operations are allowed, and sending checks a rule across its lines (none means it cannot be sent), so it is tier 2 (`lib/punch/docs/models.md`). Whether it is overdue is one rule, `Invoice::Due`, used by `Sent` and by the rows of the list queries.
- Numbers are given when an invoice is sent, without gaps: `INV-000001`, `INV-000002`, … The single writer makes "last number plus one" safe. The sequence is shared by all organizations: the issuer, from the credentials, is one.
- **Money** is an integer in minor units (`Punch::Money`) with one currency per invoice (`Punch::Currency`). Line counts (100), quantities (10,000), and unit prices (10⁹ minor units) are bounded, so every total is exact.
- Lists use keyset pages: `?after=<last id>&limit=50`; `next_after` is absent on the last page.

| Route | Operation |
|---|---|
| `GET /accounts/users/me` | `Accounts::Users::Me`: the signed-in user |
| `POST /accounts/sessions` | `Accounts::Sessions::Create`: sign in with email and password; `DELETE /accounts/sessions/:session_id` ends one, `POST /accounts/sessions/sign_out` this one |
| `POST /accounts/sign_up` | `Accounts::SignUp::Create`: a user, an address, a password, and an organization of one's own |
| `POST /accounts/password_resets` | `Accounts::PasswordResets::Create`: mails a reset link; the answer is the same for any address |
| `GET /billing/customers` | `Customers::Index` |
| `POST /billing/customers` | `Customers::Create` (201, 422 `taken` at `email`, `unsupported_locale` at `locale`) |
| `GET /billing/customers/search` | `Customers::Search` (`q`, by name in German order) |
| `GET /billing/customers/:customer_id` | `Customers::Show` |
| `PATCH /billing/customers/:customer_id` | `Customers::Update` |
| `GET /billing/customers/:customer_id/statement` | `Customers::Statement`: sent invoices per currency, cached for a minute or until an invoice is sent, `ETag` and 304 |
| `GET /billing/invoices` | `Invoices::Index` (`customer_id` optional) |
| `POST /billing/invoices` | `Invoices::Create` (201, 422 `unknown_customer`) |
| `GET /billing/invoices/:invoice_id` | `Invoices::Show` |
| `PATCH /billing/invoices/:invoice_id` | `Invoices::Update` (409 `already_sent`) |
| `DELETE /billing/invoices/:invoice_id` | `Invoices::Destroy` (204, 409 `already_sent`) |
| `POST /billing/invoices/:invoice_id/send` | `Invoices::Send` (409 `already_sent`, 422 `no_lines`) |
| `POST /webhooks/payments` | `Payments::Provider::Receive`, made by Punch: the payment provider's deliveries, stored and processed by a job (204, 401 `invalid_signature`, 404 without a secret, 409 `idempotency_key_reused`); public, not in `openapi.json` |

Pages, for browsers (`lib/punch/docs/views.md`). Each shares its path with the Query it shows: a browser gets the page, a program the JSON.

| Route | Page |
|---|---|
| `GET /billing/customers` | `Customers::IndexPage`: the list, each linked to its form |
| `GET /billing/customers/new` | `Customers::CreatePage`: the form for `Customers::Create` |
| `GET /billing/customers/:customer_id/edit` | `Customers::UpdatePage`: the form for `Customers::Update`, and the customer's invoices in a lazy frame |
| `GET /billing/invoices` | `Invoices::IndexPage`: the list, a page at a time, overdue invoices marked; for one customer inside the frame the customer's page loads |
| `GET /billing/invoices/new` | `Invoices::CreatePage`: the form for `Invoices::Create`, with three empty lines |
| `GET /billing/invoices/:invoice_id` | `Invoices::ShowPage`: one invoice, with its customer's name from a second query; a draft's buttons for `Send` and `Destroy` |
| `GET /billing/invoices/:token/shared` | `Invoices::SharedPage`: the invoice behind a shared link, without sign-in |
| `GET /accounts/sessions/new`, `/accounts/sign_up/new` | `Accounts::Sessions::CreatePage`, `SignUp::CreatePage`; a page that needs a session sends a browser without one to the first |
| `GET /accounts/sessions` | `Accounts::Sessions::IndexPage`: where the user is signed in, each with a button to end it; email addresses; the password; the language |
| `GET /accounts/emails/verify?token=`, `/accounts/password_resets/new`, `/accounts/passwords/reset?token=`, `/accounts/magic_links/new`, `/accounts/magic_links/sign_in?token=` | The pages of the mailed links, each with the form of its Command |

## Baseline (2026-10-08)

`bench/run.sh`: release build, 50 customers and 1,000 drafts, wrk with 64 connections for 10 s; 60% invoice reads, 20% list pages, 10% new drafts, 10% revisions. Linux aarch64, 8 shared cores, wrk on the same machine.

| `PUNCH_THREADS` | Requests/s | p50 | p90 | p99 |
|---|---|---|---|---|
| 1 | 28,800 | 2.0 ms | 3.3 ms | 5.3 ms |
| 2 | 47,200 | 1.3 ms | 2.5 ms | 5.1 ms |
| 4 | 47,700–49,700 | 1.1–1.2 ms | 3.3–3.7 ms | 6.7–14.3 ms |
| 8 | 41,400 | 1.3 ms | 4.9 ms | 9.2 ms |

Repeated on 2026-10-09: 29,300 requests/s at one thread (p99 4.9 ms), 49,200 at two (p99 4.7 ms), 49,600 at four (p99 7.0 ms), the same within run-to-run spread.

Reads alone at 4 threads: 66,800 requests/s, p99 3.0 ms. Writes alone: 20,500 requests/s, p99 6.4 ms (26,700 at one thread: every write hands over to the writer's thread).

## With authentication (2026-10-09)

The same bench with an API token on every request: each one now looks up the token (SHA-256, an indexed read) and loads the user, inside the write transaction for Commands. Same machine and settings:

| `PUNCH_THREADS` | Requests/s | p50 | p90 | p99 |
|---|---|---|---|---|
| 1 | 23,600 | 2.4 ms | 3.9 ms | 6.9 ms |
| 2 | 37,600 | 1.6 ms | 3.2 ms | 20.3 ms |
| 4 | 41,600–42,500 | 1.3–1.4 ms | 3.9–4.0 ms | 8.0–9.2 ms |

About 15–20% below the baseline: two more statements per request, on queries that are themselves a single indexed read or write. The last-used time of the token is written at most every five minutes, so it does not show.

## Pages (2026-10-09)

`PAGES=1 bench/run.sh THREADS 64 10` measures two pages after the mixed run, as a browser asks for them (`Accept: text/html`), signed in with the token. Same machine:

| `PUNCH_THREADS` | Mixed (JSON) | `GET /billing/invoices/42` (1 KB) | `GET /billing/invoices?limit=50` (7.9 KB) |
|---|---|---|---|
| 1 | 25,200 req/s, p99 5.6 ms | 35,800 req/s, p99 3.7 ms | 5,600 req/s, p99 14.5 ms |
| 4 | 41,300 req/s, p99 8.5 ms | 54,100 req/s, p99 11.7 ms | 7,600 req/s, p99 27.4 ms |

The mixed numbers match those with authentication: choosing between a page and a Query by `Accept` costs nothing measurable on the JSON paths. The list of 50 runs at 8,200 req/s as JSON on one thread, so its query dominates; rendering 50 rows as HTML adds about 56 µs.


## Owners (2026-10-09)

`PAGES=1 bench/run.sh 4 64 10`, three runs interleaved with the next commit on the same host (it was busier than for the tables above):

| | Next commit | Owners |
|---|---|---|
| Mixed (JSON) | 38,200 req/s, p99 8.9–9.5 ms | 37,300–39,400 req/s, p99 8.9–10.9 ms |
| `GET /billing/invoices/42` | 40,900 req/s | 39,700 req/s |
| `GET /billing/invoices?limit=50` | 7,100–7,300 req/s | 6,400–6,600 req/s |

Every operation on one invoice or customer now runs the owner lookup first, one indexed read, which the mixed load does not show. The list of 50 loses about 9%: each row links to its invoice, and a page that takes the actor asks the link's policy before writing it (`lib/punch/docs/authorization.md`), so the page makes 50 more lookups. The list query itself uses `invoices_by_owner` with no sort step.

## Organizations and roles (2026-10-13)

`PAGES=1 bench/run.sh 4 64 10`, two runs interleaved with the commit before:

| | Organizations | Before |
|---|---|---|
| Mixed (JSON) | 32,100–32,900 req/s, p99 11.5–16.9 ms | 36,000–38,300 req/s, p99 8.8–9.9 ms |
| `GET /billing/invoices/42` (page) | 28,000–28,800 req/s | 31,700–32,100 req/s |
| `GET /billing/invoices?limit=50` (page) | 4,200–4,300 req/s | 4,400–4,500 req/s |

Every request now loads the organization the actor works in (the user's live roles, read once per transaction by `Punch::Roles.held` and reused by the policy, plus two key lookups), and the policy of one invoice asks the roles about its organization instead of comparing an owner. Writes pay most, since those reads run inside the single write transaction. The 50 links of the list ask the roles without another query. A first version, one SQL query for the organization and a roles query per link, cost a third of the mixed throughput.

## Backup (2026-10-14)

The app does nothing of its own for backups: `serve` replicates `primary.db`, `queue.db`, and `ops.db` with Litestream once `PUNCH_BACKUP_URL` is set (`lib/punch/docs/backup.md`). With a directory as the replica:

```sh
PUNCH_STORAGE=/tmp/invoicing PUNCH_BACKUP_URL=file:///tmp/invoicing-replica bin/invoicing serve
bin/invoicing backup                                   # in a second shell: lag per file, Litestream
litestream restore -o /tmp/restored.db file:///tmp/invoicing-replica/primary
```

Outside development and test, `/up` fails until a replica is configured (or the files are exempted with `PUNCH_BACKUP_EXEMPT`) and the bucket is known to encrypt.

Measured with the release build against versitygw as a local S3 gateway: a graceful stop after a write leaves the restored files identical to the source (customers, 65,854 invoices, the last write) with clean integrity checks; killing Litestream, a second process on the same storage, and the app killed with Litestream left running all keep exactly one Litestream replicating. Latency under fixed-rate mixed load, with replication and without:

| Load | p99 without | p99 with | p99.9 without | p99.9 with |
|---|---|---|---|---|
| 1,000 requests/s | 1.1 ms | 1.4 ms | 8.6 ms | 10.6 ms |
| 5,000 requests/s | 4.7 ms | 5.4 ms | 7.8 ms | 18.0 ms |
| saturated (wrk, 64 connections) | 8 ms | 50 ms | | |
