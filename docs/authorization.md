# Authorization

Learn it in: [Authorization and Roles](guides/authorization-and-roles.md).

Who may run which operation. Every operation declares a policy, or says it is public; the policy runs inside the operation's transaction; a Command needs a grant that only its policy makes; forms and links on a page ask the same policy before they render.

```crystal
module Billing::Invoices
  # Only the user who created an invoice sees or changes it.
  struct Owner
    include Punch::Policy

    def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, *, invoice_id : ID) : Punch::Policy::Decision
      owner = Queries.owner(db, invoice_id: invoice_id) || return allow # a missing invoice: the operation answers 404
      owner == actor.user.id ? allow : not_found
    end
  end

  @[Punch::Authorize(Owner)]
  struct Send < Punch::Command
    alias Output = Detail | NotFound | AlreadySent | NoLines

    # ...
    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, grant : Punch::Grant(Send)) : Output
    end
  end
end
```

## Declaring

| Annotation | Means |
|---|---|
| `@[Punch::Authorize(Policy)]` | `Policy.check` decides. The operation's `call` takes the app's actor: required, or nilable where anyone may ask |
| `@[Punch::Authorize(Punch::SignedIn)]` | any signed-in user. The actor must be required, so a request without one is answered 401 before the policy |
| `@[Punch::Public]` | anyone, signed in or not: sign-in, sign-up, a shared link. No policy runs |

The build fails, at the operation, on one with neither (`punch check`, step `policies`, reads the same from `routes --json`). `punch routes` shows `(policy: Billing::Invoices::Owner)` or `(public)` on each line; the JSON has `policy` and `public`.

These do not compile: both annotations; more than one policy; a type that does not include `Punch::Policy`; a policy on an operation whose `call` takes no actor; a Command with a policy whose `call` takes no `Punch::Grant(Self)`; a grant for another operation, or for an operation without a policy; `Punch::Grant(...).new`.

## Policies

A policy is a type that includes `Punch::Policy` and defines `self.check(actor, db, **path_parameters) : Punch::Policy::Decision`:

| Decision | Shorthand | Answer |
|---|---|---|
| `Allow` | `allow` | the operation runs |
| `Forbid` | `forbid` | **403** `forbidden`: the actor may know the resource exists, but not do this |
| `NotFound` | `not_found` | **404** `not_found`: the actor must not learn that it exists |
| `Reauthenticate` | `reauthenticate` (with `Punch::Policy::RecentAuthentication`) | **403** `reauthentication_required`: the actor may, after proving again who they are |

**A policy decides from the actor, the database, and the path parameters, never from the body.** Forms and links ask it before they render, when only their path is known. A rule about the body, such as "the customer named must be one of yours", belongs to the operation, which answers with its own result. A state rule, such as "a sent invoice cannot be sent again", stays a typed result of the operation too.

An operation without path parameters calls `check(actor, db)`. One policy may serve several operations with the same path parameters (`Owner` for `Show`, `Update`, `Send`, `Destroy`). Where a resource is missing, a policy can `allow` and let the operation answer its own 404, or answer `not_found` itself; both look the same to the client. So does an ID in the path that does not parse (`docs/operations.md`). IDs that count their records, plain rowids, still tell an actor how many there are across every organization; `public_id` on the ID type hides that (`docs/core-types.md`), but grants nothing and refuses nothing: the policy is what keeps other organizations' records out. A `check` that takes `**params` opts out of the compile-time match with the operation's path parameters: for a nested route, name every ID it must check.

**Lists are authorized in SQL.** A policy decides about one operation call, not about rows: an index query takes the actor and selects only what the actor may see, so page sizes and counts stay right. With roles, it joins the view `punch_permissions` (see Roles).

## When it runs

1. Rate limits by address and input fields, then the 401 for a missing actor, as before.
2. The transaction opens (write for a Command, read for a Query or page), the actor loads, actor and token limits apply.
3. **The policy runs**, in the same transaction, so its decision cannot be raced by a concurrent change. A refusal ends the request; a Command's transaction rolls back.
4. `call` runs, a Command with the grant.

The wide event records `punch.policy` (the policy's name) and `punch.authz` (`allow`, `forbid`, `not_found`); the outcome is `forbidden` or `not_found`. The policy's queries are spans inside the transaction's span.

A browser gets Punch's problem page for a refusal. A refused form submission shows the page that holds the form again, with `forbidden` as the form's error and status 403.

## Recent authentication

Changes to how someone signs in, deleting an account, or moving money should not be possible from a browser someone left open. A policy that asks for a recent authentication includes `Punch::Policy::RecentAuthentication`:

```crystal
struct Accounts::Recent
  include Punch::Policy
  include Punch::Policy::RecentAuthentication

  def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, **params) : Punch::Policy::Decision
    recently_authenticated(db, actor.principal)
  end
end
```

`recently_authenticated` allows when the session proved who the user is within `Punch::Auth.config.recent_authentication` (15 minutes; `within:` overrides it), and, for a user with an authenticator app, when that proof included the app: a password alone no longer counts for them. Otherwise it answers `reauthenticate`; for an API token, which cannot prove anything again, `forbid`. `Punch::RecentlyAuthenticated` is the policy that asks only this; it needs an actor with a `principal` getter. Combine it with other rules by returning early: `return decision unless (decision = recently_authenticated(db, actor.principal)).allow?`.

Forms whose policy answers `reauthenticate` are left out like any other refused form; the page says why with `Punch::Policy::RecentAuthentication.recent?(db, actor.principal)` and links to the app's re-authentication page, whose Commands renew the session with `auth.renew(method: ...)` after `Auth::OwnPasswordCheck` or `Auth::OwnSecondFactorCheck` (docs/auth.md).

## Grants

`Punch::Grant(O)` proves that *O*'s policy allowed the call. A Command with a policy must take one, so code that calls it directly, a page or a job, has to ask the policy first:

```crystal
case grant = Punch::Grant(Send).check(actor, db, invoice_id: id)
in Punch::Grant(Send) then Send.new.call(input, db, actor, grant)
in Punch::Policy::Refused     then grant # 403 or 404 when returned; grant.code says which
end
```

`check` is the only way to make one in ordinary code; the constructor is private. It catches a forgotten check, it does not prove which actor or parameters were checked: code that sets out to forge one (`uninitialized`) can. A Query may take its grant as well; it then cannot be called without one either. A grant carries nothing but its type: the actor is passed beside it.

## Forms and links

On a page that takes the actor, `v.form(Command.action(...))` and `v.a(..., href: Page.href(...))` ask the policy of their operation, with the path parameters they were built with, before they render. Not permitted: the element is left out with everything in its block. The render span records how many were left out (`punch.authz.hidden`).

| Target | Shown when |
|---|---|
| operation with a policy | the policy allows the viewer |
| operation without a policy that needs an actor | the viewer is signed in |
| public operation, external link, asset | always |

Pages render inside their read transaction for this, so the policies read the same snapshot as the page. A page that does not take the actor does not know who is looking: it renders every form and link, and the targets still refuse on their own.

Each check is a call to the policy, so a list of 50 rows linking to a page with a database policy runs 50 small queries while rendering. Keep policies to one indexed lookup.

## Roles

A role is a set of operations, defined in code; who holds it, on which resource, and until when is data. A plain rule such as "only the owner" needs none of this.

```crystal
module Accounts::Roles
  # Reads everything in an organization.
  struct Member
    include Punch::Role

    scope Accounts::Organizations::ID
    permits Billing::Invoices::Index, Billing::Invoices::Show, Billing::Invoices::ShowPage
  end

  # A member who also writes and sends invoices.
  struct Accountant
    include Punch::Role

    scope Accounts::Organizations::ID
    permits Member, Billing::Invoices::Create, Billing::Invoices::Send
  end

  # Support staff: reads every organization's invoices.
  struct Support
    include Punch::Role

    permits Billing::Invoices::Show, Billing::Invoices::ShowPage
  end
end
```

- **`scope`** names the resource the role is held on by its typed ID. A role without one is **global**: held everywhere.
- **`permits`** lists operations, and roles of the same scope whose operations it includes. Pages are operations too: list the page beside the Query it shows.
- **Permissions are operations,** by their IDs (`billing.invoices.send`); there are no permission strings to keep in sync. A role's name in the data is its type's name, dotted the same way (`accounts.roles.accountant`); renaming the type needs a migration that renames the rows.

These do not compile: a role that permits nothing, a `permits` entry that is neither an operation nor a role, a role that includes one of another scope, a `scope` that is not a typed ID, assigning or revoking with the wrong resource type (or with `on:` for a global role, or without it for a scoped one).

### The policy

A policy that names `operation` as its third parameter is told which operation asks. It finds the resource the role is held on, then asks the roles:

```crystal
module Billing::Invoices
  # Whoever holds a role on the invoice's organization that permits the operation.
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

`Punch::Roles.check(db, user_id, operation, on: resource)` answers from the live assignments of the user on that resource and the global ones:

| Decision | When |
|---|---|
| `allow` | a role permits the operation |
| `forbid` (403) | the user holds a role there, or a global role, but none permits this: they may see the invoice, not send it |
| `not_found` (404) | the user holds nothing there, so learns nothing |

Without `on:` it asks the global roles only. It reads the user's live assignments once per transaction (`Punch::Roles.held(db, user_id)`, also for app code that needs them on every request) and decides from the roles as this binary's code defines them, so a page whose 50 links ask a policy costs one query for the roles; `assign` and `revoke` through the same handle make it read them again. The wide event records the roles that decided as `punch.roles` (`accounts.roles.member`, a global one marked `(global)`, or `none`). A page shows a member the invoice without the send form, and the form's Command refuses with 403: the hiding of "Forms and links" works unchanged.

### Assignments

```crystal
assignment = Punch::Roles.assign(db, user_id, Accounts::Roles::Accountant, on: organization_id,
  expires_at: 30.days.from_now, assigned_by: actor.user.id)
events.publish Punch::Roles::Assigned.new(assignment)

if ended = Punch::Roles.revoke(db, user_id, Accounts::Roles::Accountant, on: organization_id)
  events.publish Punch::Roles::Revoked.new(ended, actor.user.id)
end
```

| Function | Does |
|---|---|
| `assign(db, user, Role, on: resource, expires_at:, assigned_by:)` | gives the role; assigning a role the user holds changes only its expiry |
| `revoke(db, user, Role, on: resource)` | takes it; returns the assignment that ended, or `nil` |
| `revoke_all(db, on: resource)` | ends every assignment on a resource, for the Command that deletes it (a resource ID has no foreign key that could) |
| `assignments(db, user_id:)`, `assignments(db, on:)` | rows, expired ones included |
| `holders(db, Role, on:)` | how many hold it now, for a Command that keeps at least one administrator |

**Granting and revoking are the app's Commands,** like the sign-in flows (docs/auth.md): who may assign which role is a policy like any other, and invariants such as "an organization keeps one administrator" are the Command's. They publish `Punch::Roles::Assigned` and `Punch::Roles::Revoked`, which `punch events` and the ops console show: that is the audit trail. An expired assignment stays as a row and counts nowhere; deleting a user deletes their assignments.

### Lists: the effective permissions

`punch_permissions` is a view with one row per user, operation, and resource the user may run it on, from live assignments: `user_id`, `operation`, `resource_type`, `resource_id`, `role`. A named query joins it, so a list holds only what the actor may see and every page is full:

```sql
-- name: index
SELECT i.id, i.number FROM invoices i
WHERE i.organization_id IN (
    SELECT p.resource_id FROM punch_permissions p
    WHERE p.user_id = :user_id AND p.operation = 'billing.invoices.index' AND p.resource_type = 'accounts.organizations')
ORDER BY i.id
LIMIT :limit
```

A list across several resources ordered by anything but a column of the view reads every row the user may see and sorts it, which `punch db:explain` refuses. Where people work in one resource at a time, the reference app's pattern is simpler; see below.

A global role has `NULL` as its resource; where it should see every row, add `OR EXISTS (SELECT 1 FROM punch_permissions p WHERE p.user_id = :user_id AND p.operation = '…' AND p.resource_type IS NULL)`. A resource type is its typed ID's name, dotted, without the final `ID`: `Accounts::Organizations::ID` is `accounts.organizations`.

### Working in one organization

The reference app scopes lists and new records to the organization the actor works in, kept per session or API token:

- **The actor carries it:** `Invoicing::Actor#organization`, loaded with the user from `organization_choices` (the one the session or token chose with `Accounts::Organizations::Switch`, while the user still holds a role there), else the organization the user was given a role on first. `Accounts::Organizations::Store` loads and saves it.
- **Lists and creates** take the policy `Accounts::Organizations::Current`, which asks the roles about that organization: its operations need no path parameter, and links and forms to them disappear for a member whose role does not permit them, like any other. The list's SQL is then one index range, `WHERE invoices.organization_id = :organization_id`, with full pages.
- **A record by ID** takes `ByRole` with the record's organization, so a member can open it from a link even while working in another organization; a body field naming another record (`customer_id` in `Invoices::Create`) must belong to the current organization.
- **Members** are managed by Commands of the app (`Accounts::Organizations::Members::Create`, `Destroy`) that publish `Punch::Roles::Assigned` and `Revoked`, give a role by a verified address only, hold one role per member, and keep an administrator.

### Tables

`punch db:migration --punch roles [--users TABLE]` writes the migration (the SQL is `Punch::Roles::Schema.sql("users")`), as for sessions (docs/auth.md):

- `punch_role_assignments`: one row per user, role, and resource (`resource_type` and `resource_id`, both `NULL` for a global role), `expires_at` (nullable), `assigned_by`, `created_at`. Unique per user, role, and resource.
- `punch_role_operations`: each role's operations as this binary's code defines them. **Punch writes it**: the server when it starts, `Punch::Spec` when it loads a schema, `authz:explain` before it runs; only when it differs. Never edit it by hand.
- `punch_permissions`: the view over both. Expiry counts to the second.

`serve` refuses to start when an app with roles lacks one of them.

### Commands

| Command | Shows |
|---|---|
| `bin/<app> roles` | every role, its scope, and its operations |
| `bin/<app> roles --user ID` | a user's assignments, expired ones marked |
| `bin/<app> roles:assign ROLE --user ID \| --email ADDRESS` | gives the user a global role, by its name (`accounts.roles.operator`) or its type (`Accounts::Roles::Operator`): the first operator of a new deployment. `--email` names only a user who verified the address; anyone may claim one unverified |
| `bin/<app> roles:revoke ROLE --user ID \| --email ADDRESS` | takes a global role from the user |
| `punch authz:explain OPERATION --user ID [name=value ...]` | why the user may or may not run the operation: the policy, its decision, the roles that decided, which roles would permit it, and what the user holds |

`authz:explain` takes the operation by ID or type name and its path parameters as `name=value`, and reads the primary database in `PUNCH_STORAGE`. It runs the policy as a request would, as a session that signed in just now, in a transaction that is rolled back. It is a command of the `punch` tool, which builds the app with `-Dpunch_openapi` (the build `punch openapi` uses) and asks that binary: an explainer per operation would cost every app build compile time. All of them have `--json`. `roles:assign` and `roles:revoke` take global roles only and publish no event: they are for the box, before anyone can use the app. A role held on a resource is given by the app's own Command, which decides who may give it and publishes `Punch::Roles::Assigned`.

## OpenAPI

An operation with a policy documents **403** `forbidden` and **404** `not_found` (beside its own 404, if it has one), and **403** `reauthentication_required` when the policy includes `Punch::Policy::RecentAuthentication`. Every Command documents **403** `cross_origin_request`, the refusal of another site's page (docs/auth.md).

## Testing

- Endpoint specs see the answers like any other: `response.status`, `response.json["code"]`, `response.trace.root["punch.authz"]`.
- `Punch::Spec.grant(Send, actor, db, invoice_id: id)` runs the policy and returns the grant, for specs that call a Command directly; it raises when the policy refuses.
- `Punch::Spec.render(component, authorizer: Punch::Policy::Authorizer.new(actor, reader))` renders as a page would for *actor*; without `authorizer:`, every form and link renders.

Markdown action blocks ask the same policies: a form the viewer may not use is not described either (`docs/views.md`, "Action blocks").
