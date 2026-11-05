# Getting Started with Punch

Applies to Punch 0.1.

This guide takes you from an empty directory to a working app called `roster`, which keeps the list of a club's members. You create the app, run it, and add one feature the way you will add every feature after it: a table, the code that maps it, a Command and a Query, a page with a form, and specs. On the way you meet the loop you work in every day and the check that guards the app before every commit. Each step ends with something you can see.

After reading this guide, you will know:

- how to create an app with `punch new`, run it with `punch dev`, and sign in;
- where things live in an app, and which files you never edit;
- how to add a table with a migration and map it to typed code with `punch generate entity` and `punch db:generate`;
- how to write a Command and a Query, see their routes, and call them as JSON;
- how to show a page and a form bound to a Command, with refusals shown again;
- the working loop: `punch typecheck` after an edit, specs for the area, `punch dev` for pages, and `punch check` before you commit.

Before you start: Punch and its `punch` tool are installed ([Installing Punch](installing.md)). If Crystal is new to you, read [Crystal for Punch Developers](crystal-for-punch-developers.md) first, or keep it open beside this guide. Building the app takes about an hour, much of it waiting for the first compiles.

## 1. Create the app

`punch new` writes an app and makes it ready to run. Create `roster` in a directory on local disk ([Installing Punch](installing.md#databases-on-local-disk)):

```console
$ punch new roster
Created Roster in roster (124 files).
  done    crystal tool format
  done    shards install
  done    credentials (development)
  done    key ring (development)
...
  done    db:migrate
  done    db:generate
...
  done    db:seed
  done    punch check
  done    git init
  done    git add
  done    first commit

Next:
  cd roster
  punch dev    # then sign in as admin@example.test, the password in storage/seed-password
```

This takes a few minutes, because `punch new` does more than write files. It installs the dependencies, starts encrypted credentials and a signing key for development and test, creates the database, generates the typed code, adds a development user, and runs every check on the result. A fresh app passes `punch check`, so the first check that ever fails in it is about your own change. Last, it makes the first Git commit.

The app is not empty. It has the accounts slice: sign-up, sign-in and sign-out, password reset, email verification, a second factor with an authenticator app, API tokens, and a list of your sessions. It has a home page, a layout, an ops console for operators, deploy recipes, and a CI workflow. It has no example data model; you add the first one in this guide.

> [!NOTE]
> **Coming from Rails:** `punch new` is closer to `rails new` followed by an authentication generator, `bin/setup`, and a first green CI run. Options such as `--organizations` and `--magic-links` add optional parts of the accounts slice ([Tooling](../tooling.md#punch-new)). See [Coming from Rails](coming-from-rails.md#the-map).

**Checkpoint:** `cd roster` and `git log --oneline` shows one commit.

## 2. Find your way around

Every file in a Punch app has one place, and the name of a type tells you which. The top of the app:

```text
roster/
  AGENTS.md           how to work on this app, for people and coding agents
  README.md           running, checking, and deploying it
  app/                the app's code, one directory per part of the domain
    accounts/         the accounts slice that punch new wrote
    components/       the layout and components shared by slices
    home/             the home page
    actor.cr          who a request acts for: the signed-in user
    credentials.cr    what the app needs from its deployment
    setup.cr          every declaration that configures Punch
    requires.gen.cr   generated: requires every file under app/
  config/
    credentials/      encrypted credentials per environment; *.key is never committed
    locales/          the text people read, per language
  db/
    migrations/       the schema changes, in SQL
    schema.sql        generated: the schema the migrations produce
    seeds.cr          development data, made through the app's own Commands
  scripts/
    punch-tool.sh     gets the punch tool of the app's version, for CI and the devcontainer
  spec/               specs, mirroring app/
  src/
    main.cr           the binary's entry point
    roster.cr          requires Punch and the app, for the binary and specs
  storage/            the SQLite databases (development); not committed
  openapi.json        generated: the JSON API as OpenAPI
```

A directory under `app/` is a namespace: `app/accounts/sessions/` holds `Accounts::Sessions`. Inside it, the directories `operations/`, `pages/`, `jobs/`, `mail/`, `subscribers/`, and `components/` name a kind of file and add no namespace. So `Accounts::Sessions::Create`, the Command that signs someone in, is in `app/accounts/sessions/operations/create.cr`, and its page `Accounts::Sessions::CreatePage` in `app/accounts/sessions/pages/create_page.cr`. [Application Structure](application-structure.md) has every rule.

Files ending in `.gen.cr`, `db/schema.sql`, `openapi.json`, and `payloads.lock.json` are generated. They are committed, so a review shows what changed, but you never edit them: change their source and run the generator. The app's `AGENTS.md` has the table of which command writes which file.

**Checkpoint:** open `app/accounts/sessions/operations/create.cr` and find `Create`. It is about 30 lines, and nothing in it mentions HTTP.

## 3. Run it with `punch dev`

`punch dev` builds the app, starts it, and does both again whenever you save a file:

```console
$ punch dev
punch dev: building src/main.cr
punch dev: started in 24.2 s: http://127.0.0.1:3000
```

The first build takes the longest. Open <http://127.0.0.1:3000>. You are sent to sign in, because the home page needs a signed-in user. Sign in as `admin@example.test` with the password in `storage/seed-password`, the user `db/seeds.cr` made. You land on the home page, with the navigation of the layout at the top. That user is an operator, so the **Ops** link opens the ops console at `/_punch`, which shows requests, jobs, and errors ([The Ops Console](the-ops-console.md)).

Each request prints its trace in the terminal: the request, its status and result, the time, and every SQL statement it ran, by name:

```text
GET / 200 welcome  1.28 ms  queries 3  trace 4332b21f28aa4985bfebbf207a4373b1
    +0.08    0.02 ms  input
    +0.13    1.05 ms  primary read
...
```

Each round of `punch dev` applies new migrations, regenerates generated files, rebuilds, and restarts the app. A failed step prints its error and leaves the running app as it was, so you fix and save. A change to a stylesheet or image needs no build: the page reloads with it at once. Leave `punch dev` running in its own terminal for the rest of this guide.

**Checkpoint:** you are signed in, and the terminal shows your requests.

## 4. The loop you work in

Before adding code, here is the rhythm every change follows. It is the same for a person and for a coding agent, and the app's `AGENTS.md` states it for both:

1. **Edit, then `punch typecheck`.** It regenerates the typed code, then type-checks the app without building it: a few seconds, with every error and its location. Most mistakes in a Punch app are compile errors, and this is where you meet them.
2. **Run the specs of the area you changed**, such as `crystal spec spec/members/`. Each example gets a fresh database.
3. **Look at it in `punch dev`** when the change shows on a page.
4. **Run `punch check` before you commit.** It runs everything CI runs: the formatter, the schema and generated files, the lint rules, the query plans, the build, the policy and rate-limit checks, the OpenAPI document, and the specs. When it passes, the change is ready.

When a check fails, its message says what to do. Do the honest fix; never edit a generated file, loosen a check, or disable a rule to make one pass ([`punch check` and the Command Line](punch-check-and-the-command-line.md)).

The rest of this guide follows the loop.

## 5. A table for members

Data starts with a migration: SQL that changes the schema. Create one:

```console
$ punch db:migration create_members
Created db/migrations/20261030142818_create_members.sql
```

Write the table into it:

```sql illustrative="the tutorial's migration, as you write it"
-- db/migrations/20261030142818_create_members.sql
-- Members: the people who belong to the club.
CREATE TABLE members (
  id         INTEGER PRIMARY KEY,
  name       TEXT    NOT NULL,
  email      TEXT    NOT NULL UNIQUE,
  created_at TEXT    NOT NULL
) STRICT;
```

`STRICT` makes SQLite refuse a value of the wrong type; Punch requires it. Times are stored as text in ISO 8601. The `UNIQUE` on `email` is the rule that no two members share an address, kept by the database itself.

`punch dev` applies the migration on its next round. To apply it yourself:

```console
$ punch db:migrate
Applied 20261030142818_create_members.sql
Wrote db/schema.sql
```

Migrations only go forward. Once a migration is committed, you never change it: a correction is a new migration ([Migrations](migrations.md)).

**Checkpoint:** `db/schema.sql` now ends with the `members` table.

## 6. An entity for members

The members need a home in `app/`: the entity `Members`, in `app/members/`. `punch generate entity` writes what follows from that structure:

```console
$ punch generate entity members
  created  app/members.cr
  created  app/members/types.cr
  created  app/members/columns.cr
  created  app/members/queries.sql
  done    db:generate
  done    requires:generate

Next:
  Write the outline in app/members.cr.
  Map the columns listed in app/members/columns.cr to their domain types.
  Add operations under app/members/operations/ and pages under app/members/pages/, with specs in spec/members/.
  punch check
```

It writes no operations, pages, or SQL of its own. Those are yours. Work through its list.

`Members` is a slice, a directory directly under `app/`, and an entity, a namespace that owns a table. As an app grows, a slice groups the entities of one part of the domain: `punch generate entity library/books` makes `Library::Books` in `app/library/books/` ([Application Structure](application-structure.md)).

### The outline

`app/members.cr` is an outline: one documented module, saying what the namespace means. It starts with a placeholder line that `punch check` reports until you replace it. Write what it is for, in plain words:

```crystal illustrative="the tutorial's outline, as you write it"
# app/members.cr
# The members of the club: a name to address and an email address to
# reach them at. No two members share an address. Every signed-in user
# sees and adds the same members.
module Members
end
```

Outlines are where a reader, or an agent, learns the domain before reading code ([Domain Models](domain-models.md)).

### The columns

`columns.cr` says which domain type each column holds. The generator mapped the ID and the time, and listed the rest as plain strings. Map them:

```crystal illustrative="the tutorial's columns.cr, as you write it"
# app/members/columns.cr
# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "members", Members,
  id: Members::ID,
  name: Punch::NonEmptyString,
  email: Punch::Email,
  created_at: Time
```

A name is now a `Punch::NonEmptyString`, and an email a `Punch::Email`, which is checked and lowercased when it is parsed. Code that reads a member gets those types, never a bare `String`. `types.cr` already holds `Members::ID`, so a member's ID cannot be mixed up with a user's.

### A named query

SQL lives in `queries.sql`, beside the code that uses it. Each query has a name, and `punch db:generate` turns it into a typed method. Add one that lists members a page at a time:

```sql illustrative="the tutorial's queries.sql, as you write it"
-- app/members/queries.sql
-- name: Page :page
-- The members, a page at a time, newest last.
-- scan: a page reads the table in rowid order and stops at its limit
SELECT * FROM members
WHERE true
-- order created: ORDER BY id
```

`:page` makes a keyset-paged query: each page ends with a cursor that the next page starts after. A page continues by a condition in `WHERE`, so a query without one writes `WHERE true`. The `-- scan:` line accepts that the query reads the table without an index, and says why that is fine here. Without it, `punch check` would report the scan ([Keeping SQL Safe and Fast](keeping-sql-safe-and-fast.md)).

Generate the code:

```console
$ punch db:generate
unchanged app/accounts/users/records.gen.cr
written   app/members/records.gen.cr
written   app/members/queries.gen.cr
1 queries (0 with annotations), 2 mapped tables (0 with behaviour), 1 violation types.
```

`records.gen.cr` holds `Members::Record`, a typed row, and `Members::Table`, which finds, inserts, updates, and deletes one row. It also holds `EmailTaken`, a result type made from the `UNIQUE` index: inserting a second member with the same address returns it instead of raising. `queries.gen.cr` holds `Members::Queries.page` ([Named Queries and Generated Code](named-queries.md)).

**Checkpoint:** `punch typecheck` says `src/main.cr type-checks`.

## 7. A Command and a Query

An app does things through operations. A **Query** reads and answers; a **Command** changes something. Each is one struct in its own file, and Punch derives its route from its name.

### What the API returns

First, the shape a member has in an answer. A database row is never a response, so this is its own type, in `results.cr`, the namespace's file for result types:

```crystal illustrative="the tutorial's results.cr, as you write it"
# app/members/results.cr
module Members
  # A member as the API shows it.
  @[Punch::Status(200)]
  struct Member
    include JSON::Serializable

    getter id : ID
    getter name : Punch::NonEmptyString
    getter email : Punch::Email
    getter created_at : Time

    def initialize(record : Record)
      @id = record.id
      @name = record.name
      @email = record.email
      @created_at = record.created_at
    end
  end
end
```

### Adding a member

The Command that adds a member:

```crystal illustrative="the tutorial's Create, as you write it"
# app/members/operations/create.cr
module Members
  @[Punch::Status(201)]
  struct Created
    include JSON::Serializable

    getter member : Member

    def initialize(@member : Member)
    end
  end

  # Adds a member. No two members share an email address.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter name : Punch::NonEmptyString
      getter email : Punch::Email
    end

    alias Output = Created | EmailTaken

    def call(input : Input, db : Punch::Writer, actor : Roster::Actor, _grant : Punch::Grant(Create)) : Output
      case created = Table.insert(db, name: input.name, email: input.email, created_at: Time.utc)
      in Record     then Created.new(Member.new(created))
      in EmailTaken then created
      end
    end
  end
end
```

Read it from the top:

- **`@[Punch::Authorize(Punch::SignedIn)]`** is the policy: any signed-in user may add a member. Every operation names a policy, or says `@[Punch::Public]`, or it does not compile. A Command with a policy takes its proof, `Punch::Grant(Create)`, in `call`.
- **`Input`** is what a request must carry. Punch parses it before `call` runs: an empty name or a malformed address never reaches your code, and the client gets a 422 naming each field ([Input and Domain Types](input-and-domain-types.md)).
- **`alias Output`** lists everything `call` can return. Each result type has a status: `Created` is 201, and `EmailTaken` is a 422 at the field `email`.
- **`call`** asks for what it needs by type: the input, a `Punch::Writer` (a Command runs in one write transaction), the signed-in user, and the grant.
- **`case … in`** handles each outcome of the insert. If you leave out the `EmailTaken` branch, the app does not compile:

  ```text
  In app/members/operations/create.cr:25:7

   25 | case created = Table.insert(db, name: input.name, email: input.email, created_at: Time.utc)
        ^
  Error: case is not exhaustive.

  Missing types:
   - Members::EmailTaken
  ```

  This is how Punch handles failures you expect: as values the compiler makes you handle, not exceptions someone might forget to rescue ([Results, Errors, and Status Codes](results-errors-and-status-codes.md)).

### Listing members

The Query that lists them, a page at a time:

```crystal illustrative="the tutorial's Index, as you write it"
# app/members/operations/index.cr
module Members
  # One page of members.
  struct Page
    include JSON::Serializable

    getter members : Array(Member)
    # Pass as `after` for the next page; absent on the last one.
    getter next_after : Queries::Page::Cursor?

    def initialize(page : Punch::Paged(Record, Queries::Page::Cursor))
      @members = page.map { |record| Member.new(record) }
      @next_after = page.next_after
    end
  end

  # Lists the members in the order they were added, a page at a time.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input

      getter after : Queries::Page::Cursor?
      getter limit : Punch::PageSize = Punch::PageSize.of(50)
    end

    alias Output = Page

    def call(input : Input, db : Punch::Reader, actor : Roster::Actor) : Output
      Page.new(Queries.page(db, after: input.after, limit: input.limit))
    end
  end
end
```

A Query gets a `Punch::Reader`, which cannot write. That is why a Query can never change data by accident.

Type-check, then look at the routes Punch derived:

```console
$ punch typecheck
src/main.cr type-checks (3.2 s).
$ punch routes
...
GET     /members                      json                Members::Index
POST    /members                      json                Members::Create
...
```

You wrote no route. The namespace gives the path, `Index` a `GET` on it, and `Create` a `POST` ([Operations and Routing](operations-and-routing.md)). Name an operation after what it does, and the route follows.

**Checkpoint:** `punch routes` lists both operations.

## 8. Call it as JSON

Every operation is a JSON endpoint as well. A program authenticates with an API token. Make one for the development user, whose ID is 1:

```console
$ punch tokens:create --user 1 --name curl
ros_97dT5BjAk6206Ah8nevXg58wwO0Y4RMrOGLYdqetiPQ12EBTJ
Token 1 for user 1, expires 2026-11-29 19:09. It is shown only now.
```

`tokens:create` is a command of the app's own binary; `punch` builds the app and runs it for you. Use the token you got (here in `$TOKEN`) to add a member:

```console
$ curl -X POST http://127.0.0.1:3000/members \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name": "Ada Lovelace", "email": "ada@example.org"}'
{"member":{"id":1,"name":"Ada Lovelace","email":"ada@example.org","created_at":"2026-10-30T19:09:25Z"}}
```

That is a `201 Created`. Send the same address again, and the unique index answers through `EmailTaken`, as a Problem Details document with status 422:

```console
$ curl -X POST http://127.0.0.1:3000/members \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name": "Ada Again", "email": "ada@example.org"}'
{"type":"about:blank","title":"Unprocessable Entity","status":422,"code":"invalid_input","request_id":"5483f4b33bd0ba48bccf237ad5989fb7","detail":"Some of the input is not valid.","errors":[{"path":["email"],"code":"taken","params":{},"message":"Is already taken."}]}
```

Input that does not parse never reaches `call`. Every problem is reported at once:

```console
$ curl -X POST http://127.0.0.1:3000/members \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name": "", "email": "nope"}'
{"type":"about:blank","title":"Unprocessable Entity","status":422,"code":"invalid_input",...,"errors":[{"path":["name"],"code":"blank","params":{},"message":"Must not be empty."},{"path":["email"],"code":"invalid_email","params":{},"message":"Is not an email address."}]}
```

And the list:

```console
$ curl http://127.0.0.1:3000/members -H "Authorization: Bearer $TOKEN"
{"members":[{"id":1,"name":"Ada Lovelace","email":"ada@example.org","created_at":"2026-10-30T19:09:25Z"}]}
```

Without the token, the answer is `401 Unauthorized`. The trace of the first request shows what happened inside: the token check, the user, and the insert, all in one transaction:

```text
POST /members 201 created  1.55 ms  queries 4  trace a66e44c7e70174fec1d42673157179d8
    +0.08    0.31 ms  input
    +0.42    0.87 ms  primary write wait_ms=0.226
    +0.84    0.12 ms    Punch::Auth::APITokens.find rows=1
    +1.01    0.02 ms    Punch::Auth::APITokens.touch changes=1
    +1.04    0.03 ms    Accounts::Users::Table.find rows=1
    +1.14    0.07 ms    Members::Table.insert rows=1
```

**Checkpoint:** the list holds Ada Lovelace.

## 9. Pages and a form

People use pages. A page is an operation too, a `Punch::Page`, which calls Queries and renders components. HTML is written in Crystal, element by element, so every value is escaped and every link is typed.

### The list page

```crystal illustrative="the tutorial's IndexPage, as you write it"
# app/members/pages/index_page.cr
module Members
  struct ListView
    include Punch::Component

    def initialize(@page : Page, @actor : Roster::Actor, @next_page : Punch::Href?)
    end

    def view(v : Punch::View) : Nil
      t = v.t.members
      v.render Roster::Layout.new(t.title, @actor) do
        v.h1 t.title
        v.p { v.a t.new_member, href: CreatePage.href }
        if @page.members.empty?
          v.p t.none
        else
          v.table do
            v.thead { v.tr { [t.name, t.email].each { |label| v.th label, scope: "col" } } }
            v.tbody do
              @page.members.each do |member|
                v.tr do
                  v.td member.name.to_s
                  v.td member.email.to_s
                end
              end
            end
          end
        end
        if next_page = @next_page
          v.p { v.a t.next_page, href: next_page, rel: "next" }
        end
      end
    end
  end

  # The members, a page at a time: `GET /members` in a browser.
  @[Punch::Authorize(Punch::SignedIn)]
  struct IndexPage < Punch::Page
    alias Input = Index::Input

    alias Output = ListView

    def call(input : Input, db : Punch::Reader, actor : Roster::Actor) : Output
      page = Index.new.call(input, db, actor)
      next_page = page.next_after.try { |after| IndexPage.href(after: after, limit: input.limit) }
      ListView.new(page, actor, next_page)
    end
  end
end
```

`IndexPage` shares its path with the `Index` Query: a browser asking for HTML gets the page, a program asking for JSON gets the Query. `punch routes` now shows both, and `Create` answering forms as well as JSON. The page calls the Query rather than the database, so both answer the same. `ListView` is a component: a struct with a `view` method, rendered inside the app's layout ([Pages and Components](pages-and-components.md)).

### The form

```crystal illustrative="the tutorial's CreatePage, as you write it"
# app/members/pages/create_page.cr
module Members
  struct NewView
    include Punch::Component

    def initialize(@actor : Roster::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.members
      v.render Roster::Layout.new(t.new_member, @actor) do
        v.h1 t.new_member
        v.form(Create.action) do |form|
          form.field :name
          form.field :email
          form.submit t.add
        end
      end
    end
  end

  # The form that adds a member: `GET /members/new`.
  @[Punch::Authorize(Punch::SignedIn)]
  struct CreatePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = NewView

    def call(input : Input, db : Punch::Reader, actor : Roster::Actor) : Output
      NewView.new(actor)
    end

    # Where the browser goes after the member was added.
    def self.redirect(result : Created) : Punch::Href
      IndexPage.href
    end
  end
end
```

`v.form(Create.action)` binds the form to the Command. Each `form.field` takes its input type, its `required`, and its label from `Create::Input`; a field the input does not have does not compile. When the Command succeeds, the browser is sent on with a `303` to where `redirect` says. When it refuses, the same page is shown again with what was typed and the reason at each field ([Forms](forms.md)).

### The text

The text people read comes from `config/locales/en.yml`, never from string literals in pages. Add the keys the pages use, and a link in the layout's navigation:

```diff illustrative="the tutorial's change to config/locales/en.yml"
   layout:
     main: "Main"
     home: "Home"
+    members: "Members"
     ops: "Ops"
     signed_in_as: "Signed in as"
     account: "Account"
     sign_out: "Sign out"
+  members:
+    title: "Members"
+    new_member: "New member"
+    none: "No members yet."
+    name: "Name"
+    email: "Email"
+    next_page: "Next page"
+    add: "Add member"
```

```diff illustrative="the tutorial's change to app/components/layout.cr"
                 chrome.a t.home, href: Home::IndexPage.href
+                chrome.text " "
+                chrome.a t.members, href: Members::IndexPage.href
                 # Shown to operators only: the link asks the console's policy.
```

`punch i18n:generate`, which `punch dev` and `punch typecheck` run for you, turns the keys into methods, so `v.t.members.title` is checked at compile time ([Translations and Formats](translations-and-formats.md)). The labels of `name` and `email` come from the `fields` the accounts slice already has.

Save, and `punch dev` rebuilds. In the browser, follow **Members**, then **New member**. Add Grace Hopper with `grace@example.org`: you are back on the list, and she is in it. Add her again: the form comes back with her name still filled in and "Email: Is already taken." above the form and at the field.

**Checkpoint:** the list in the browser shows the members you added through `curl` and through the form.

## 10. Specs

Specs mirror `app/`: the spec for `operations/create.cr` is `spec/members/create_spec.cr`. A spec talks to the app as a client does, through its routes, and every example starts with an empty database.

```crystal illustrative="the tutorial's spec, as you write it"
# spec/members/create_spec.cr
require "../spec_helper"

describe "adding a member" do
  it "adds a member and lists it" do
    client = AccountsSpec.client
    response = client.post(Members::Create.path, json: {name: "Ada Lovelace", email: "ada@example.org"})
    response.status.should eq(HTTP::Status::CREATED)
    response.json["member"]["email"].should eq("ada@example.org")

    listed = client.get(Members::Index.path).json["members"].as_a
    listed.map(&.["name"]).should eq(["Ada Lovelace"])
  end

  it "refuses a second member with the same address" do
    client = AccountsSpec.client
    client.post(Members::Create.path, json: {name: "Ada Lovelace", email: "ada@example.org"})
    response = client.post(Members::Create.path, json: {name: "Ada Again", email: "ada@example.org"})
    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.json["errors"][0]["path"].should eq(JSON.parse(%(["email"])))
    response.json["errors"][0]["code"].should eq("taken")
  end
end
```

`AccountsSpec.client` is a factory from `spec/support/accounts.cr`: a client signed in as a new user. `Create.path` is the typed path of the Command, so a renamed operation breaks the spec at compile time instead of at a 404. The page has a spec of its own, which fills in the form as a browser would:

```crystal illustrative="the tutorial's page spec, as you write it"
# spec/members/create_page_spec.cr
require "../spec_helper"

describe "the member form" do
  it "adds a member and leads back to the list" do
    client = AccountsSpec.client
    form = client.visit(Members::CreatePage.href)
    form.should have_element("form[action='/members'] input[name=email]")

    response = client.submit(Members::Create.action, form: {"name" => "Grace Hopper", "email" => "grace@example.org"})
    response.should redirect_to(Members::IndexPage.href)
    client.visit(Members::IndexPage.href).should have_element("td", text: "grace@example.org")
  end

  it "shows the form again with the reason it was refused" do
    client = AccountsSpec.client
    refused = client.submit(Members::Create.action, form: {"name" => " ", "email" => "grace@example.org"})
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.should have_field_error("name", "blank")
  end
end
```

Run the specs of the entity:

```console
$ crystal spec spec/members/
....

Finished in 39.56 milliseconds
4 examples, 0 failures, 0 errors, 0 pending
```

Each spec also checks every JSON answer against the OpenAPI document, so a response that drifts from what the API promises fails here ([Testing Punch Applications](testing-punch-applications.md)).

**Checkpoint:** four examples pass.

## 11. `punch check`, then commit

Run the whole check:

```console
$ punch check
passed  format        0.0 s  src, spec, app, db
passed  schema        0.0 s  db/schema.sql matches the migrations.
passed  migrations    0.0 s  6 migrations: 6 instant, 0 scan, 0 rebuild; 1 new since main
...
failed  openapi       1.3 s
passed  specs        14.2 s  37 examples, 0 failures, 0 errors, 0 pending (CRYSTAL_WORKERS=4)
passed  nocache       0.2 s  37 examples, 0 failures, 0 errors, 0 pending (PUNCH_CACHE=off CRYSTAL_WORKERS=4)
punch: 1 check failed: openapi

== openapi
openapi.json does not match the operations. Run 'punch openapi' and commit the result; never edit it by hand.
```

The new operations changed the API, and `openapi.json` is the committed description of it. `punch dev` does not rewrite it on every save, because that takes a second build. Do what the message says:

```console
$ punch openapi
written   openapi.json (26 operations, 39 schemas)
$ punch check
...
passed  openapi       1.5 s  current   openapi.json (26 operations, 39 schemas); against main: No breaking changes.
...
All checks passed: 21 passed, 2 skipped, 38.4 s.
```

"Against main" means the check compared the API with the `main` branch and found no change a client would break on. Now commit, generated files included:

```console
$ git add --all
$ git commit -m "Members: add and list them, as JSON and as pages"
```

**Checkpoint:** `punch check` passes, and the commit holds the migration, the schema, the entity, its operations, pages, specs, texts, and `openapi.json`.

## What to read next

You have used most of what a Punch app is made of. Each guide below goes deeper into one part:

- [How a Punch App Works](how-a-punch-app-works.md): the map of everything you touched, from the socket to the database and into the background.
- [Application Structure](application-structure.md): where every other kind of file goes.
- [Domain Models](domain-models.md): when a record is not enough, because a thing has states and rules for moving between them.
- [Forms](forms.md): the rest of what a form can do, such as custom layouts and buttons that change a state.
- [Authorization and Roles](authorization-and-roles.md): policies beyond "signed in", such as only an admin removing a member.
- [Background Jobs](background-jobs.md) and [Mail](mail.md): welcoming a new member by mail without slowing the request.
- [Deploying](deploying.md): the recipe `punch new` wrote, and what happens on deploy.

For a larger app built the same way, with slices, roles, background jobs, and live pages, read the reference app in Punch's `reference/` directory.

## Common mistakes

**Leaving the outline placeholder in place.** `punch check` fails at lint with:

```text message=src/punch/ameba/namespace_file.cr
`punch generate` left this outline for you to write: say what `Members` means and is for, in plain words, in place of this line (lib/punch/docs/models.md)
```

Write the sentence it asks for. It is the first thing the next reader of the code, or an agent, reads.

**A page query without a condition.** `punch db:generate` refuses a `:page` query without `WHERE`:

```text message=src/punch/query_gen/keyset.cr
app/members/queries.sql:6:1: query Page: a page continues by a condition in WHERE; write one, `WHERE true` if nothing else
```

**A scan nobody accepted.** `punch check` fails at `explain` when a query reads a whole table:

```text message=src/punch/query_gen/explain.cr
app/members/queries.sql:6:1: query Page reads every row of members. Add an index that serves it, or say why it is fine in the header: `-- scan: <reason>`.
```

Add an index when the query filters or sorts by a column. Write `-- scan:` only with a true reason, as for the page above, which stops at its limit.

**Editing a generated file.** A fix in `queries.gen.cr` or `openapi.json` is overwritten by the next `punch dev`, and `punch check` fails on it before that:

```text message=src/punch/cli/tool.cr
app/members/queries.gen.cr does not match the schema and queries. Run 'punch db:generate' and commit the result; never edit generated files by hand.
```

Change the source (`queries.sql`, `columns.cr`, the operations) and run the generator.

## Limits

- `punch dev` rebuilds the whole app on each change other than an asset's. On a small app a rebuild takes 10 to 25 seconds; `punch typecheck` is the fast check between edits.
- This guide's code is checked by hand against Punch 0.1. Replaying the tutorial automatically, as the docs check does for quoted code, is not built yet.

## Reference

- [Tooling](../tooling.md): `punch new`, `punch generate`, `punch dev`, `punch check`, and the settings.
- [Application structure](../structure.md): every place a file can go.
- [Operations](../operations.md), [Queries](../queries.md), [Views](../views.md), and [Testing](../testing.md): every option of what this guide used.
