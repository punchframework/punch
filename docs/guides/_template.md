# Title: the task or concept, in the reader's words

Applies to Punch 0.1.

One paragraph: what this is, and why it matters to an app. Name the problem it solves before the mechanism.

After reading this guide, you will know:

- how to do the first thing (a capability, not a topic);
- how to do the second;
- why Punch refuses the habit a reader brings, and what to do instead.

Before you start: the guides this one builds on, and the state of the app it assumes.

## The first concept or task

The first section gets the reader to a working result. Its first sentence restates the context, so the section reads well on its own.

Quote the reference app by definition, never by hand:

    ```crystal source=reference/app/billing/invoices/operations/send.cr select=Billing::Invoices::Send elide=call
    ```

Then run `punch docs:check --write`, which fills the block in. Add `bare` where the definition's doc comment and annotations have nothing to do with the section: they show as `# ...`. Quote only what the section is about; select a method, elide the bodies that do not matter, or use the examples app. Other kinds of block:

    ```crystal fails=spec/fail/secret_to_json.cr
    ```

    ```text
    Error: the compiler's message, from spec/core/compile_errors_spec.cr
    ```

    ```crystal illustrative="why this is not quoted"
    ```

    ```console
    $ punch check
    ```

A message quoted from Punch names the file that gives it, so the check keeps it current; `message=crystal` (or `sqlite`, `turbo`) marks another program's:

    ```text message=src/punch/ameba/sql_text.cr
    SQL text from a value: pass a literal or a constant, …
    ```

> [!NOTE]
> **Coming from Rails:** at most two of these per guide, one short paragraph each, ending with a link into [Coming from Rails](coming-from-rails.md).

## Further sections, one concept each

Later sections add options and depth. A heading says the thing ("Retries and backoff"), never a pun: headings are anchors, and links break when one changes.

## Common mistakes

For each mistake: what a reader or an agent would plausibly do, the exact message they see in a `text message=PATH` block, why Punch refuses it in one sentence, and the honest fix. Say so where a quick fix would defeat the check.

## Limits

What is not supported, or not built yet.

## Rules

- Short imperative lines, each checkable, each linking to its section.

## Reference

- [The reference page](../core-types.md) for every option.
