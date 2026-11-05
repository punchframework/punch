# AGENTS.md

Guide for anyone, person or coding agent, working on this app. It is built on Punch; Punch's docs are in `lib/punch/docs/<topic>.md`, and every Punch message cites them by that path. `punch new` wrote this file; change it as the app grows.

## The loop

1. After every edit: `punch typecheck` (a few seconds; `--json` gives the errors as data). It regenerates queries, translations, and `app/requires.gen.cr` first, then type-checks without building.
2. For one area: `crystal spec spec/accounts/sessions/` (specs mirror `app/`, below). An exception inside an operation fails the example with its message and backtrace (`Punch::Spec::ServerError`), not as a bare 500.
3. Before finishing: `punch check --json`. Every step must be `passed` or `skipped` (`steps[].status`); a failed step's `detail` says what to do.
4. While working on pages: `punch dev` rebuilds and restarts on every save and prints each request's trace. Sign in as `admin@example.test` with the password in `storage/seed-password` (`db/seeds.cr`; `punch db:seed` adds it again to a new database).

Never skip a check or a hook to make it pass, and never edit a generated file (below). `punch help` lists the commands; a command of the app's binary (`jobs:versions`, `db:audit`, `roles:assign`) also runs as `punch <command>`.

## Where a thing goes

A namespace is a directory: `Accounts::Sessions` is `app/accounts/sessions/`, and a file's outermost module is its directory's namespace. The directories `operations/`, `pages/`, `jobs/`, `mail/`, `subscribers/` and `components/` name a kind of file and add no namespace. A slice is a directory under `app/`; every operation is in a namespace below it, in the one whose state it writes (a Query: whose state it reads most), and a verb becomes a resource where the action is that REST action on it (`Accounts::Sessions::Create` signs in, `POST /accounts/sessions`). A use case that writes several entities gets a namespace of its own, without tables (`Accounts::SignUp`).

| Thing | File |
|---|---|
| Settings (`Punch.*` declarations, `Punch::*.config =`) | `app/setup.cr`, never in a type's file |
| The actor, credentials, languages | `app/actor.cr`, `app/credentials.cr`, `app/languages.cr` |
| A layout or component shared by slices | `app/components/`, one file each |
| What a namespace means (its outline) | `app/accounts/users.cr`, beside its directory: a documented module, every namespace directory has one, slices too |
| Domain primitives and IDs (`ID`, a `Number`) | `types.cr` of the entity that owns them; the slice's `types.cr` holds only what the slice shares |
| Events | `events.cr` in the slice |
| Column types | `columns.cr` of the entity that owns the table (`Punch.table`); records are generated beside it |
| Behaviour of a generated record | `record.cr` beside `columns.cr` (`Shop::Orders::Record` in `app/shop/orders/record.cr`) |
| A model with states, a store, a helper type | a file named after its type: `app/shop/orders/order.cr` (`Shop::Orders::Order`), `store.cr` |
| SQL | `queries.sql` in the entity's directory, turned into methods by `punch db:generate` |
| Results, inputs, policies shared in a namespace | `results.cr`, `inputs.cr`, `policies.cr` |
| Operation `Accounts::Sessions::Create` | `app/accounts/sessions/operations/create.cr`, with the result types only it returns |
| Job, mail, subscriber | `jobs/`, `mail/`, `subscribers/` of the namespace it serves, one file per type named after it; a mail used across the slice is in `app/accounts/mail/` |
| Page `Accounts::Sessions::IndexPage` | `app/accounts/sessions/pages/index_page.cr`, with the components only it renders |
| Components shared in a namespace | `components.cr` |
| Roles | `app/accounts/roles.cr` |
| Schema changes | a new file from `punch db:migration NAME` |
| Punch's own tables | `punch db:migration --punch outbox\|idempotency\|webhooks\|uploads\|auth\|roles` |
| Secrets | values with `punch creds:set` |
| Text for people | `config/locales/*.yml` and `config/locales/accounts/*.yml`, read as `v.t.…` |
| Development data | `db/seeds.cr`, through the app's own Commands (`punch db:seed`) |
| Specs | `spec/<slice>/<namespace path>/<file>_spec.cr` for each app file (`spec/accounts/sessions/create_spec.cr`); journeys across namespaces in `spec/journeys/`; factories per slice in `spec/support/<slice>.cr` (`AccountsSpec`) |

No file needs a require: `app/requires.gen.cr` (`punch requires:generate`, run by `typecheck`, `dev`, and `check`) requires every file under `app/` in the order of its kind, and refuses a file of no kind with the list (`lib/punch/docs/structure.md`). `punch check` reports a file in the wrong place (`Punch/OperationFile`, `Punch/RecordFile`, `Punch/NamespaceFile`, `Punch/SetupFile`) with the right path.

## Adding a slice

1. A migration for the entity's table (`punch db:migration create_<table>`), then `punch db:migrate`.
2. `punch generate entity <area>/<entity>`: the outlines, `types.cr` with the ID, `columns.cr` mapping the table, `queries.sql`. Write each outline's doc comment in place of its `# punch generate:` line, saying what the slice or entity means and is for; map the columns `columns.cr` lists to their domain types; add queries; then `punch db:generate`. A namespace without tables: `punch generate namespace <area>/<name>`.
3. Texts in `config/locales/en.yml`, then `punch i18n:generate`.
4. Specs, mirroring the new files; then `punch check`.

## Adding to the accounts slice

`punch generate accounts PART` adds a part `punch new` left out, as it would have written it: `magic_links`, sign-in by a link in an email; `organizations`, organizations, members, roles held on them, and the current organization; `second_factor`, a second factor (TOTP and recovery codes); `tokens`, API tokens for programs and agents. It replaces the files the app has left as the template wrote them; the template's change to an edited file goes to `tmp/generate/accounts-PART.patch`, to apply with `git apply` or by hand.

## After updating Punch

`punch upgrade:diff` shows how the template `punch new` used changed for this app since the previous Punch, as a patch in `tmp/upgrade/` with each file's status (`lib/punch/docs/tooling.md`). Nothing is applied for you: apply what fits (`git apply --3way` merges files the app edited), then `punch check`.

## Never edit

| File | Change it with |
|---|---|
| `*.gen.cr` | its source, then `punch db:generate`, `punch i18n:generate`, or `punch requires:generate` |
| `db/schema.sql` | a new migration, then `punch db:migrate` |
| an applied migration | a new migration |
| `openapi.json` | `punch openapi` |
| `payloads.lock.json` | `punch jobs:lock` |
| `config/credentials/*` | `punch creds:edit`, `punch creds:set` |

## Which construct?

| Need | Use | Doc |
|---|---|---|
| Read and answer | a `Punch::Query` (takes a `Punch::Reader`) | `operations.md` |
| Change something | a `Punch::Command` (takes a `Punch::Writer`); a failure (status from 400) rolls back | `operations.md` |
| HTML for people | a `Punch::Page` calling operations, rendering components | `views.md` |
| A form | `v.form(Command.action(...))` on the Command's page | `views.md` |
| Slow, retryable, or calling out | a job (a `record` that includes `Punch::Job`), enqueued through `jobs : Punch::Jobs(...)` in `call` | `jobs.md` |
| Long: walks many rows, or waits on another system | a job with steps (`include Punch::Job::Stepped`, methods marked `@[Punch::Job::Step]`), resumed where it stopped | `jobs.md`, "Long jobs: steps" |
| React to a change | an event (a `record` that includes `Punch::Event`; `events : Punch::Events(...)`) and a subscriber: after commit by default, `:deferred` for mail and calls out, `:inline` rarely | `events.md` |
| Update open pages | `live` on the page; prefer `refresh`, which re-renders under the viewer's policy | `views.md` |
| Something expensive to compute | a `Punch::Cache` in a Query, forgotten by an after-commit subscriber | `cache.md` |
| Who may do it | `@[Punch::Authorize(Policy)]` or `@[Punch::Public]` on every operation | `authorization.md` |
| Limit abuse | `@[Punch::RateLimit(...)]`; every Command without a signed-in user needs one or `@[Punch::RateLimitExempt("reason")]` | `rate-limits.md` |
| "Now" | `Time.utc`; specs stop it with `Punch::Spec.clock` | `testing.md` |
| A failure result | a struct with `include Punch::Problem` and `@[Punch::Status(4xx)]` | `openapi.md` |
| Text search | `-- when q: AND name LIKE '%' \|\| :q \|\| '%' ESCAPE '\'`; the parameter is a `Punch::LikeText` | `queries.md` |
| Personal data or a stored secret | a `BLOB` column mapped as `Punch::Encrypted(T)` in `columns.cr`; records hold `Punch::Secret(T)`, `unwrap` it only where it is shown | `queries.md` |
| A file from a user | a kind (`include Punch::Upload::Kind` with `@[Punch::Upload::Rules]`), a Command that grants, a `Punch::Upload::Ticket` field in the Command that claims; the record keeps the claimed file as a group, `scan: {type: Punch::Upload::File, columns: "scan_"}`, or `PrivateFile` when its name can be personal data, `ImageFile` and `PrivateImageFile` for images; `scan: true` in the kind's rules when a job scans them, then link with `href?`; a key is never taken from a request | `uploads.md` |
| A value object on a row, or a snapshot, small list, or several fields kept together | a composite, `Punch.composite` in `composites.cr` or `columns.cr`, stored as a group of prefixed columns or a JSON document; make one with `build` | `composites.md` |
| Find or keep unique an encrypted value | a blind index beside it, `email_index: Punch::BlindIndex.of(:email)` on a `BLOB` column with a (unique) index; queries compare it only as `email_index = :email` | `queries.md` |
| Encrypt a column that holds plaintext already | three releases: a new `BLOB` column mapped `Punch::Encrypted(T).from(:column)`, then `from(:column, clear: true)`, then drop the old column; `punch db:encrypt` converts in between | `queries.md` |
| A page of a list | a `:page` query, `limit : Punch::PageSize` in the input, `_by_key` for one row of it | `queries.md` |
| Who runs the app | the global role `Accounts::Roles::Operator`, which opens the ops console at `/_punch`; give it on the box with `punch roles:assign Accounts::Roles::Operator --email ADDRESS` | `ops.md` |

`call` asks for what it needs by type, in any order after the input and the handle; the full list is in `lib/punch/docs/operations.md`, "What `call` takes".

## Error → fix

| Message starts with | Fix |
|---|---|
| `… needs a policy, @[Punch::Authorize(Policy)], or @[Punch::Public]` | annotate the operation; copy a policy from `policies.cr` |
| `… declares what call returns as alias Output`, `…#call returns : Output` | put `alias Output = A \| B` right above `call`, the union of everything it returns, and end the signature with `: Output` |
| `… is a Command that runs without a signed-in user, so it needs a rate limit` | add `@[Punch::RateLimit(...)]`, or `@[Punch::RateLimitExempt("reason")]` with a real reason |
| `…#call can return X, which has no @[Punch::Status]` | give every result type a status; failures `include Punch::Problem` |
| `… is a database row, not a response` | return a result struct with the fields to show, never a `Record` or `Row` |
| `…#call takes Punch::Grant(…), but … has no policy` | add `@[Punch::Authorize(Policy)]` |
| `expected argument #1 to 'Punch::Events(…)#publish'` | add the event to `Punch::Events(A \| B)` in `call` |
| `no overload matches 'Queries.…' with types …, q: String` | the parameter is a `Punch::LikeText`: pass `Punch::LikeText.new(text)`; `.pattern(raw)` only for deliberate wildcards |
| `case is not exhaustive. Missing types: …` | handle the new result or state with another `in` branch |
| `requires`: stale, or `no file kind fits …` | `punch requires:generate`; name the file after the type it holds, or make it one of the listed kinds |
| `policies` or `limits` step fails | as the compile errors above; the binary was built without them |
| `queries`: stale generated file | `punch db:generate` |
| `i18n`: `the problem X has no message` | add `problems.X` (or `errors.X`) to `config/locales/en.yml` |
| `explain`: full scan or sort | add an index or change the query; `-- scan: <reason>` only with a real reason |
| `schema`: `db/schema.sql` does not match | `punch db:migrate`; never edit the schema file |
| `applied migrations were changed afterwards` | revert the edit and put the change in a new migration |
| `X is not STRICT` | `CREATE TABLE … STRICT` in a new migration |
| `events`: `Events that no operation publishes` | publish it from a Command or delete it |
| `openapi`: stale | `punch openapi`; on a breaking change, rethink it or bump the major version |
| `payloads`: a change breaks stored payloads | make the field nilable or defaulted, or raise the job's payload version; for a removed or renamed step, keep it until no run is unfinished, then `punch jobs:lock --drop 'Type#step'` (`jobs.md`) |
| `punchtables`: a Punch table differs | write the migration the message names |
| `… reaches into the … slice's data` | call that slice's operations or policies, or add a function to that slice for what you need (`Accounts::Mailing`) |
| `… in an operation calls another system` | move the call into a job enqueued through `jobs : Punch::Jobs(...)`, or a `:deferred` subscriber |
| `Handle the nil instead of not_nil!` | `\|\| return NotFound.new`, or a `case` on the union |
| `… holds a collection in a stored payload` | store the IDs and read the rows when the job runs |
| `… look like what scanners ask for` | rename the route or asset; only if the path must stay, take the pattern out in `app/setup.cr` (`Punch::HTTP::Probes::Patterns.default.without(...)`, `http.md`) |

## Rules no tool checks yet

You are the check for these:

- Blank lines: after a guard clause (`return … unless …`) before the code it guards; after the `include` lines that open a body; between an `Input`'s path parameters and its other fields; before and after a `case`, unless it opens or closes a method or block.
- No sentence for people as a string literal in a page, component, or problem; text comes from the locale files.
- Dates, numbers, and money through `v.locale` (`.date`, `.number`, `.money`), never `to_s`.
- `live` handlers that build a row must check that the viewer may see it themselves; `refresh` is safe.
- Never query `punch_*` tables from app SQL, except the public view `punch_permissions`.
- A seed in `db/seeds.cr` goes through the app's Commands and looks before it adds; it never writes rows a Command would refuse.

## More

- `README.md`: running, checking, and deploying the app.
- `lib/punch/docs/`: one file per topic (`operations.md`, `queries.md`, `views.md`, `testing.md`, …).
- `punch routes`, `punch events`: what the macros derived, as Punch sees it.
