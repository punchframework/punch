# Working with Coding Agents

Applies to Punch 0.1.

Punch is built for developers who write much of their code with coding agents and review it themselves. An agent knows a lot of Rails and TypeScript, much less Crystal, and nothing about Punch, which is newer than its training. So the app has to tell it what to do, and the checks have to catch what it gets wrong. This guide shows what a new app already gives an agent, how to add your own rules to that, and what to look at when you review the result.

After reading this guide, you will know:

- what `AGENTS.md` gives an agent, and how to extend it;
- how an agent finds Punch's documentation and gets from an error to its fix;
- which loop keeps an agent's work honest, and which shortcuts to forbid;
- what to look at first when you review an agent's change;
- how to write a request an agent can finish;
- how an agent reads a running app.

Before you start: you have created an app ([Getting Started with Punch](getting-started.md)) and know the checks ([`punch check` and the Command Line](punch-check-and-the-command-line.md)). The guide works with any coding agent that can read files and run commands.

## What a new app gives an agent

`punch new` writes an `AGENTS.md` at the root of the app, for people and agents alike, and a `CLAUDE.md` that points to it. It is short enough to read in one go, and it holds what an agent would otherwise guess:

- **The loop:** what to run after an edit, for one area, and before finishing.
- **Where a thing goes:** a table from each kind of thing to its file.
- **Adding a slice:** the steps, in order.
- **Never edit:** each generated file, and the command that changes it.
- **Which construct?** A table from a need ("slow, retryable, or calling out") to the construct and its reference page.
- **Error to fix:** the start of each message an agent is likely to meet, and what to do.
- **Rules no tool checks yet:** the conventions that are yours to enforce, such as no sentence for people as a string literal in a page.

The rest of the app does the same work without being read. A type's name decides its file and route, so there is one place for each thing. And a new app passes `punch check`, so the first failure an agent sees is about its own change.

## Extending `AGENTS.md`

`AGENTS.md` is yours: `punch new` wrote it once, and `punch upgrade:diff` shows what changed in the template, without applying anything. Add what an agent cannot learn from the code:

- what the app is for, in a paragraph, and the words your domain uses;
- rows in "Where a thing goes" and "Which construct?" for your own conventions;
- rules specific to this app, such as "every money amount is in the customer's currency";
- how to reach a staging system, or what never to touch.

Say each rule as a short imperative an agent can follow literally, and name the check or the file behind it. Keep it short: an agent reads the whole file on every task, and a rule buried in a long file gets lost. A rule that a type, a lint rule, or a spec can enforce belongs there rather than here, since a check does not forget.

Write the meaning of each slice and entity in its outline, the documented module beside its directory ([Application Structure](application-structure.md)), rather than in `AGENTS.md`. An agent reads the outline when it works there.

## Pointing an agent at the documentation

Punch's documentation ships with it. After `shards install`, `lib/punch/docs/` holds the pages for the exact version the app uses, so an agent never reads about a different release. `lib/punch/docs/llms.txt` is the index: one line per guide and reference page, saying what each answers.

Every message Punch gives cites its page by that path:

```text message=src/punch/routing.cr
Billing::Invoices::Send needs a policy, @[Punch::Authorize(Policy)], or @[Punch::Public]: an operation without either would run for anyone (lib/punch/docs/authorization.md).
```

So an agent goes from an error to its explanation without searching. A guide's "Rules" section states its invariants as imperatives, and its "Common mistakes" section holds exact messages, so searching the docs for a message lands on the fix. [When the Compiler Says No](when-the-compiler-says-no.md) collects the compile errors. The app's own copy of `AGENTS.md` and these pages are all an agent needs, with no network.

## The loop that keeps an agent honest

The loop is in `AGENTS.md`, and it is the one you use yourself:

1. After every edit, `punch typecheck --json`. It regenerates what is generated and type-checks the whole app in a few seconds, with the errors as data.
2. For the area it changed, `crystal spec spec/billing/invoices/`.
3. While working on pages, `punch dev`, which rebuilds on every save and prints each request's trace.
4. Before finishing, `punch check --json`. Every step must be `passed` or `skipped`, and a failed step's `detail` says what to do.

An agent drives these without parsing text: `--json` puts exactly one JSON document on stdout, also on failure, and exit codes are 0, 1, and 2 ([For scripts and agents](punch-check-and-the-command-line.md#for-scripts-and-agents)). Tell an agent that it has finished when `punch check --json` says so, not when its code looks right.

When a check fails, the honest fix is the one that keeps the guarantee. An agent under pressure to turn a line green reaches for one of these, and each of them defeats the check. Forbid them in your request, and look for them in review:

| When this fails | The honest fix | Never |
|---|---|---|
| A generated file is stale | Run its generator | Edit the `.gen.cr` file by hand |
| `explain` reports a full scan | Add an index, or change the query | Add `-- scan:` without a real reason |
| A lint rule reports a line | Change the code | Add `ameba:disable` without a reason a reviewer would accept |
| `db:audit` reports rows | Fix the rows | Loosen the type, or coerce on read |
| A Command needs a rate limit | Add `@[Punch::RateLimit]` | Add `@[Punch::RateLimitExempt]` with a made-up reason |
| An operation needs a policy | Write the policy | Mark it `@[Punch::Public]` |
| The contract check fails a spec | Fix the response, or change the type and run `punch openapi` | Work around the check |
| A spec fails | Fix the code, or the spec if it is wrong | Skip it, or rescue the failure |
| An applied migration is wrong | Add a new migration | Edit the applied file |

## Reviewing an agent's change

An agent's diff can be long, and most of it is usually fine. Punch's generated files are committed, so the diff also shows what the change does to the app, in files a person can read quickly. Start there, not with the code:

- **`openapi.json`:** what changed for API clients. A new operation, a new field, a removed one.
- **`db/schema.sql` and new migrations:** what changed in the data. Run `punch db:cost` on anything new, and read any `-- rebuild:` it acknowledges ([What a migration costs](migrations.md#what-a-migration-costs)).
- **`payloads.lock.json`:** which job payloads changed.
- **`punch routes`:** every operation with its surfaces, policy, and limits. A new line without a policy you expected stands out.

Then read for what no check can decide. These are the lines a reviewer exists for:

- **`@[Punch::Public]`, `@[Punch::RateLimitExempt("…")]`, `-- scan:`, `ameba:disable`:** each states a reason. Is it true?
- **A policy:** does it check the record in the path, and what does a member of another organization get? The compiler proves that a policy exists, not that it is right.
- **`.unwrap` on a secret:** does this reader get to see the value?
- **`Punch.cannot_violate`:** can that write really not break a constraint?
- **A new column:** should it be encrypted ([Column Encryption and Blind Indexes](column-encryption.md))?
- **A removed or renamed column or field:** does the previous release still read it ([Evolving a Live App](evolving-a-live-app.md))? `punch check` cannot see that.
- **Specs:** do they test the app's decisions, including the refused paths, or only that the happy path answers 200?

Generated code is ordinary Crystal in a committed file. When a change surprises you, read `queries.gen.cr`, and the diff shows what the method now does.

## Requests an agent can finish

A good request names the outcome, the rules, and how to know it is done. This one is complete:

```text
Add a way to cancel a sent invoice. Only someone who may send invoices may
cancel one. A paid invoice cannot be cancelled. Cancelling mails the customer.

Follow AGENTS.md. Add specs for each refusal. Finish when `punch check --json`
passes. Do not add a rate-limit exemption or a `-- scan:` comment; if you think
one is needed, stop and tell me why.
```

It says what a domain expert would say, and leaves the types to the agent. The compiler then does part of the review: a new `Cancelled` state makes every `case … in` over an invoice stop compiling until it says what to do.

A few habits help:

- **Copy from a working example.** "Do it as `Billing::Invoices::Send` does" gives an agent a complete file to follow. The slice in [The Reference Slice, Annotated](the-reference-slice-annotated.md) is written for that.
- **Keep one change to one concern.** A migration that a later release relies on goes in its own change.
- **Name what is a decision.** "Ask me before changing the API" stops an agent from settling it by itself.
- **Ask for the failure first.** For a bug, ask for a spec that reproduces it, then the fix.

## An agent on a running app

An agent can read a running app the way an operator does. The surfaces are built for it:

- **`/llms.txt`** lists an app's agent-readable pages, and each page answers as markdown with its forms as action blocks ([Pages for Agents](pages-for-agents.md)).
- **The ops console** answers as markdown too: `/_punch/errors.md` is the list of open error groups, with a link to each one's backtrace and stored wide event.
- **`punch ops --json`,** on the box or with `--url` against a running app, gives the same reports as data ([The Ops Console](the-ops-console.md)).

That makes a loop an agent can run on a schedule: read an open error, follow its wide event to the operation and the named query, write a spec that reproduces it, propose the fix as a pull request, and let `punch check` verify it. You decide what ships.

Give an agent its own user and its own token. Its requests then carry its identity on their wide events, its role limits what it can do, and you revoke the token when it is done ([Tokens for agents](pages-for-agents.md#tokens-for-agents)). Its token is a credential: keep it out of the repository and out of `AGENTS.md`.

## Common mistakes

**Letting an agent edit a generated file.** The next `punch db:generate` overwrites the edit, and until then `punch check` fails:

```text message=src/punch/cli/tool/openapi.cr
openapi.json does not match the operations. Run 'punch openapi' and commit the result; never edit it by hand.
```

Change the source, and run the command the message names.

**Trusting "the tests pass".** An agent that runs one spec file has not run the checks. Ask for `punch check --json`, and let CI run it again.

**Accepting a reason nobody checked.** `@[Punch::RateLimitExempt("internal use")]` compiles, and so does any other sentence. A reason is only worth what a reviewer makes of it.

**Teaching rules only in `AGENTS.md`.** A rule in prose fails silently. When an agent breaks one twice, give the rule a type, a lint rule, or a spec.

**Letting a long `AGENTS.md` grow.** A file that tries to hold everything is a file nobody applies. Link to a page instead of copying it: the docs are already in `lib/punch/docs/`.

## Limits

- `punch check` cannot see which columns the previous release reads, whether a policy is right, or whether a reason is true. Those stay with the reviewer.
- The rules under "Rules no tool checks yet" in `AGENTS.md` are yours to enforce.
- An agent's token acts with its user's permissions. There are no separate scopes for agents beyond what that user's role allows.
- Punch does not run an agent for you. The loops here are yours to schedule, with the agent of your choice.

## Rules

- Keep `AGENTS.md` short, and add what the code cannot say. ([Extending `AGENTS.md`](#extending-agentsmd))
- Turn a rule that keeps being broken into a check. ([Extending `AGENTS.md`](#extending-agentsmd))
- Count work as done when `punch check --json` passes. ([The loop that keeps an agent honest](#the-loop-that-keeps-an-agent-honest))
- Never make a check pass by loosening it. ([The loop that keeps an agent honest](#the-loop-that-keeps-an-agent-honest))
- Review `openapi.json`, the schema, and the payload lock first, then every stated reason. ([Reviewing an agent's change](#reviewing-an-agents-change))
- Give an agent its own user and token, and keep the token out of the repository. ([An agent on a running app](#an-agent-on-a-running-app))

## Reference

- [Tooling](../tooling.md): every command and `--json` mode.
- [`punch check` and the Command Line](punch-check-and-the-command-line.md): each step, and what it protects.
- [Pages for Agents](pages-for-agents.md) and [The Ops Console](the-ops-console.md): what an agent reads on a running app.
- Next: [The Reference Slice, Annotated](the-reference-slice-annotated.md).
