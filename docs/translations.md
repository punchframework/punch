# Translations and formats

Learn it in: [Translations and Formats](guides/translations-and-formats.md).

Text for people in more than one language, and dates, numbers, and money in each language's format. Programs read codes; people read messages rendered from them at the edge.

## Locale files

Rails-style YAML in `config/locales/`, one mapping per file under its locale tag. Any number of files per locale, in subdirectories too; a key defined twice is an error.

```yaml
# config/locales/en.yml
en:
  invoices:
    title: "Invoices"
    numbered: "Invoice %{number}"
    line_count:
      one: "%{count} line"
      other: "%{count} lines"
```

- `%{name}` is filled in from an argument of that name; `%%{` writes `%{`.
- A mapping whose keys are plural categories (`zero one two few many other`) and that has `other` is a plural message. Which forms a locale needs comes from Punch's plural table (`Punch::I18n::Plural`): `one`/`other` for English and German; `one`/`few`/`many`/`other` for Polish and Russian; `other` alone for Japanese. `zero` is allowed everywhere and wins for 0, as in Rails.
- `~` or an empty value is a missing text.

Punch reads eight namespaces by name; everything else becomes a typed accessor:

| Namespace | Holds |
|---|---|
| `errors.<code>` | The message of an error code in a rejection (`too_long`, your `invalid_invoice_number`); its params fill it in (`%{max}`) |
| `problems.<code>` | The message of a whole problem (`not_found`, your `already_sent`); a failure result's scalar fields fill it in |
| `fields.<name>` | A form field's label; without one, the name humanized (`company_name` is "Company name") |
| `llms` | The app's text in `/llms.txt`: `llms.title`, `llms.summary`, and per entry point `llms.pages.<operation id>.title` and `.description` (`docs/views.md`, "Discovery") |
| `date`, `time`, `number` | Formats, as in Rails (below), so rails-i18n files fit |
| `punch` | Punch's own messages (`punch.errors.too_long`) and currency symbols (`punch.currencies.EUR`) |

Punch ships its messages and formats in English and German (`src/punch/locales/`). An app's files may override any of these keys; a locale Punch does not ship needs all of them (the check below lists them).

## Generated accessors

Declare the type once, with the default locale:

```crystal
# app/setup.cr
Punch.translations Invoicing::Translations, default: "en"
```

`punch i18n:generate` writes `translations.gen.cr` next to it: the type, one method per key with the `%{…}` names as named arguments, and the catalog of every message in every locale, Punch's included. Commit it; the generated require file loads it first (`docs/structure.md`). Never edit it.

```crystal
v.t.invoices.numbered(number: invoice.number.to_s) # in a view
locale.t.invoices.line_count(count: lines.size)    # anywhere with a locale
t = v.t.invoices                                    # a namespace in a variable
```

- An unknown key, a missing argument, or a misspelled name does not compile: they are methods. The accessors follow the **default** locale's files.
- Arguments are `String`, `Int32`, `Int64`, or `Float64` (`Punch::I18n::Arg`); pass domain types with `.to_s`. A plural takes `count : Int`.
- Keys and argument names are lowercase letters, digits, and `_`, and no Crystal keyword (`new`, `class`, `end`). The generator says which.
- A declaration whose `default:` differs from the generated file's does not compile.

An app without `Punch.translations` uses Punch's own catalog, so rejections and problem pages have messages in English and German anyway.

## Which locale

A request's locale (`context.locale`, `v.locale`) is, in order:

1. **The actor's stored choice**: the app's actor overrides `def locale : Punch::LocaleTag?`, usually from a column of the user (the reference app's `users.locale`). It applies once the operation loads the actor, and on the error path of a rejected input.
2. **`Accept-Language`**: highest `q` first; a tag matches exactly, else by language (`de-AT` finds `de`, `de` finds `de-CH`).
3. **The default locale.**

A response rendered in a locale says so in `Content-Language`; one whose locale came from `Accept-Language` adds `Vary: Accept-Language`. The wide event has `punch.locale`. A JSON success that rendered nothing in a locale has neither header.

An operation that needs the locale takes it in `call`, like the actor:

```crystal
def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, locale : Punch::Locale) : SignedUp
```

**Mail and jobs use the recipient's stored locale**, never the request's that triggered them: store the tag with the user and build the locale in the job with `Punch::I18n.locale(tag)` (the tag, its language, or the default).

URL prefixes (`/de/invoices`) are not built yet.

## Codes at the edge

Rejections carry codes and params, never sentences (`docs/core-types.md`). The edge renders them:

- **Problem Details** gain `detail`, the problem's message, and each entry of `errors` a `message`. Programs keep reading `code`; `openapi.json` describes both as optional strings.
- **Forms** show the message at the field and in the summary, with the code in `data-code`. `have_field_error(name, code)` matches the code, whatever the language.
- **Punch's problem page** shows the message above the code.

A code without a message renders as the code.

## Formats

On any `Punch::Locale`:

| Call | English | German |
|---|---|---|
| `locale.date(time)` | `2026-03-05` | `05.03.2026` |
| `locale.date(time, :long)` | `March 5, 2026` | `5. März 2026` |
| `locale.time(time, :short)` | `05 Mar 14:07` | `05. März, 14:07 Uhr` |
| `locale.number(1234567)` | `1,234,567` | `1.234.567` |
| `locale.number(1234.5, 2)` | `1,234.50` | `1.234,50` |
| `locale.money(amount, eur)` | `€1,250.00` | `1.250,00 €` |
| `locale.strftime(time, "%A")` | `Thursday` | `Donnerstag` |

- Formats come from the locale files: `date.formats.{default,short,long}` and `time.formats.*` are `strftime` patterns whose `%B %b %A %a` come from `date.month_names` and friends, `%p` from `time.am`/`time.pm`; `number.format.{separator,delimiter,precision}`; `number.currency.format.{format,negative_format}` with `%u` the unit and `%n` the number.
- **Money** has as many decimals as its currency's minor unit (`Punch::Currency#minor_unit`, ISO 4217: `JPY` none, `KWD` three, most two). The unit is `punch.currencies.<CODE>` where the locale names one, else the code.
- **Time zones** are not converted: pass the time in the zone to show (`time.in(location)`), from the standard library.
- No CLDR: what a locale file does not say, Punch does not know.

## Checks

`punch i18n:generate --check`, the `i18n` step of `punch check`, fails when:

- the generated file is stale;
- a locale lacks a key of the default locale, has one the default lacks, or uses other `%{…}` names for it;
- a plural lacks a form its locale's rule needs, or has one the rule never uses;
- a locale lacks Punch's own keys (one finding, with the count);
- the app's code has an error code (`Punch::Invalid.new("…")`) or a failure result (`@[Punch::Status(4xx/5xx)]`, not a component) without a message in the default locale.

It also reports keys no call reaches (`t.invoices.title`, or `t.title` where the file assigns `t = v.t.invoices`), without failing: a key reached another way shows up there too.

## Testing

- `client.language = "de"` sends `Accept-Language` with every request of a `Punch::Spec::Client`.
- `Punch::I18n.locale("de")` is a locale for unit specs: `Billing::Invoices.title(locale, number, id)`.
- Specs of Punch's own catalog and the generator: `spec/i18n/`; the generator's fixture app is `spec/i18n/fixture/` (regenerate inside it after changing the generator).

## Not in scope

Right-to-left layout, a translation management interface, per-tenant overrides, and translated operation IDs or field names in action blocks (deliberately: agents copy them; the phrases around them follow the locale). The ops console stays in English.
