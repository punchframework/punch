# Compile errors

<!-- Written by `punch docs:check --write` from spec/core/compile_errors_spec.cr and spec/fail/. Do not edit: change the source and run it again. -->

What Punch's compile-time checks say, by topic. The message is the start of what the compiler prints; the rest of it names the fix and the page that explains it. Each example is the smallest program that gives it. How to read them, and the fixes that keep the guarantee: [When the Compiler Says No](../guides/when-the-compiler-says-no.md).

## Operations and routing

Explained in [Operations and routing](../operations.md).

| Message | Example |
|---|---|
| `Route collision: ArchiveAlias and Invoices::Archive both answer POST` | [route_collision](../../spec/fail/route_collision.cr) |
| `` Invoices::Index is a Command, but `Index` is reserved for Queries `` | [route_command_as_index](../../spec/fail/route_command_as_index.cr) |
| `` Invoices::Create is a Query, but `Create` is reserved for Commands `` | [route_query_as_create](../../spec/fail/route_query_as_create.cr) |
| `Logout is a Command and cannot answer GET` | [route_command_on_get](../../spec/fail/route_command_on_get.cr) |
| `the path /hooks/:provider has parameters ["provider"], but the input's path parameters are ["source"]` | [route_override_params](../../spec/fail/route_override_params.cr) |
| `Ping has no Input` | [route_without_input](../../spec/fail/route_without_input.cr) |
| `` Invoices::Purge is a Query, so its `call` receives a Punch::Reader `` | [query_with_writer](../../spec/fail/query_with_writer.cr) |
| `` Invoices::Show.path: unknown path parameter `id` `` | [path_unknown_param](../../spec/fail/path_unknown_param.cr) |
| `` Invoices::Show.path: missing path parameter `invoice_id` (Int64) `` | [path_missing_param](../../spec/fail/path_missing_param.cr) |
| `` Invoices::Show.path: `invoice_id` must be InvoiceID, not CustomerID `` | [path_wrong_type](../../spec/fail/path_wrong_type.cr) |
| `Notes::Index is a Query; only a Command reads a body, so only a Command takes Punch::RawRequest` | [raw_request_in_query](../../spec/fail/raw_request_in_query.cr) |
| `Notes::Index: @[Punch::Idempotency] is for Commands; a Query changes nothing` | [idempotency_on_query](../../spec/fail/idempotency_on_query.cr) |
| `Notes::Create takes no actor, so its keys need a scope: @[Punch::Idempotency(scope: :ip)]` | [idempotency_without_scope](../../spec/fail/idempotency_without_scope.cr) |
| `Logins::Create signs in or out (Punch::Auth::Authentication or Punch::Auth::PasswordCheck), so it takes no idempotency key` | [idempotency_on_sign_in](../../spec/fail/idempotency_on_sign_in.cr) |
| `Notes::Create: @[Punch::Idempotency(scope:)] is :ip or :anyone, not :email` | [idempotency_bad_scope](../../spec/fail/idempotency_bad_scope.cr) |
| `Notes::Index needs a policy, @[Punch::Authorize(Policy)], or @[Punch::Public]` | [operation_without_policy](../../spec/fail/operation_without_policy.cr) |

## Input

Explained in [Input](../input.md).

| Message | Example |
|---|---|
| `Settings#options has type Hash(String, String), which Punch::Input cannot parse` | [input_unsupported_type](../../spec/fail/input_unsupported_type.cr) |
| `Amount#value has type (Int32 \| String), which Punch::Input cannot parse` | [input_union_type](../../spec/fail/input_union_type.cr) |
| `Schedule#days has type Days, which Punch::Input cannot parse` | [input_flags_enum](../../spec/fail/input_flags_enum.cr) |
| `path parameter Show#slug must be a single, required value` | [input_optional_path_param](../../spec/fail/input_optional_path_param.cr) |
| `Create#lines is an array of inputs, which a query string cannot carry` | [input_nested_in_query](../../spec/fail/input_nested_in_query.cr) |

## Core types

Explained in [Core types](../core-types.md).

| Message | Example |
|---|---|
| `` NoParse includes Punch::Primitive but defines no `self.parse` `` | [primitive_without_parse](../../spec/fail/primitive_without_parse.cr) |
| `PublicNew#initialize must be private` | [primitive_public_initialize](../../spec/fail/primitive_public_initialize.cr) |
| `private method 'new' called` | [primitive_new_from_outside](../../spec/fail/primitive_new_from_outside.cr) |
| `private method 'new' called` | [typed_id_new_from_outside](../../spec/fail/typed_id_new_from_outside.cr) |
| `Punch::Secret cannot be serialized to JSON` | [secret_to_json](../../spec/fail/secret_to_json.cr) |
| `Punch::Secret cannot be serialized to JSON` | [secret_serializable](../../spec/fail/secret_serializable.cr) |
| `Punch::Secret cannot be serialized to YAML` | [secret_to_yaml](../../spec/fail/secret_to_yaml.cr) |
| `Punch::Secret cannot be hashed` | [secret_hash_key](../../spec/fail/secret_hash_key.cr) |
| `A Punch::Secret cannot be a span attribute` | [secret_span_attribute](../../spec/fail/secret_span_attribute.cr) |
| `have the same prefix; give each ID type its own` | [public_id_same_prefix](../../spec/fail/public_id_same_prefix.cr) |
| `` ::Plans::ID has a public form, so the table plans needs `INTEGER PRIMARY KEY AUTOINCREMENT` `` | [public_id_rowid_reuse](../../spec/fail/public_id_rowid_reuse.cr) |

## JSON endpoints and OpenAPI

Explained in [JSON endpoints and OpenAPI](../openapi.md).

| Message | Example |
|---|---|
| `Ledger::Customers::Record is a database row, not a response: return a result struct with the fields to show` | [record_as_response](../../spec/fail/record_as_response.cr) |
| `` Conflict#status: `status` is a Problem Details member (RFC 9457) `` | [problem_member](../../spec/fail/problem_member.cr) |
| `Odd: @[Punch::Status] takes a status from 200 to 599, not 99` | [status_out_of_range](../../spec/fail/status_out_of_range.cr) |
| `Notes::Create#call can return Notes::Missing, which has no @[Punch::Status]` | [status_missing_in_union](../../spec/fail/status_missing_in_union.cr) |
| `Missing includes Punch::Problem, so it needs @[Punch::Status(code)] with a status from 400 to 599` | [problem_without_status](../../spec/fail/problem_without_status.cr) |
| `Missing includes Punch::Problem, so it needs @[Punch::Status(code)] with a status from 400 to 599` | [problem_status_below_400](../../spec/fail/problem_status_below_400.cr) |

## Persistence

Explained in [Persistence](../persistence.md).

| Message | Example |
|---|---|
| `SQL argument 1 is Punch::Email; bind Nil, Bool, Int32, Int64, Float64, String, Bytes, or Punch::Database::Values` | [sql_argument_type](../../spec/fail/sql_argument_type.cr) |
| `Row#read: cannot read Time from SQLite` | [sql_read_type](../../spec/fail/sql_read_type.cr) |
| `undefined method 'exec' for Punch::Reader` | [query_exec](../../spec/fail/query_exec.cr) |

## Migrations

Explained in [Migrations](../migrations.md).

| Message | Example |
|---|---|
| `migrations_badly_named/create_a.sql: migration files are named <14-digit timestamp>_<name>.sql` | [migration_name](../../spec/fail/migration_name.cr) |
| `Punch.migrations: an app has one migrations directory, and it is already declared` | [migrations_declared_twice](../../spec/fail/migrations_declared_twice.cr) |
| `Punch.migrations: no directory` | [migrations_no_directory](../../spec/fail/migrations_no_directory.cr) |

## Queries

Explained in [Queries](../queries.md).

| Message | Example |
|---|---|
| `notes.body: Plain is not a domain primitive, Time, Bool, or a composite, so a column cannot map to it` | [columns_not_domain](../../spec/fail/columns_not_domain.cr) |
| `NoteID is stored as Int64, but the column holds String` | [stored_mismatch](../../spec/fail/stored_mismatch.cr) |
| `notes.body: Array(String) is not a domain primitive, Time, Bool, a composite, or a stored type, so a column cannot encrypt it` | [encrypted_unmappable](../../spec/fail/encrypted_unmappable.cr) |
| `notes.body_index: Punch::BlindIndex.of takes an encrypted column of notes, such as Punch::BlindIndex.of(:email)` | [blind_index_source](../../spec/fail/blind_index_source.cr) |
| `no overload matches 'Queries.customers_matching' with types Punch::Reader, q: String` | [like_text_string](../../spec/fail/like_text_string.cr) |
| `case is not exhaustive for enum State` | [filter_enum_missing_member](../../spec/fail/filter_enum_missing_member.cr) |
| `undefined method 'payed?' for State` | [filter_enum_unknown_member](../../spec/fail/filter_enum_unknown_member.cr) |
| `` Tags::Rename returns Tags::NameTaken, a violation of tags.name at the field `name`, but its input has no field `name` `` | [violation_field_missing](../../spec/fail/violation_field_missing.cr) |

## Domain models

Explained in [Domain models](../models.md).

| Message | Example |
|---|---|
| `` abstract `def Due#due_at()` must be implemented by Queries::Page::Row `` | [behaviour_missing_field](../../spec/fail/behaviour_missing_field.cr) |
| `this method must return (Time \| Nil), which is the return type of the overridden method Due#due_at(), or a subtype of it, not String` | [behaviour_field_type](../../spec/fail/behaviour_field_type.cr) |

## JSON Schema

Explained in [JSON Schema](../json-schema.md).

| Message | Example |
|---|---|
| `Plain has no JSON Schema` | [schema_unsupported_type](../../spec/fail/schema_unsupported_type.cr) |
| `Stamped#at has a JSON converter, so its schema cannot be derived` | [schema_converter](../../spec/fail/schema_converter.cr) |

## Views and pages

Explained in [Views and pages](../views.md).

| Message | Example |
|---|---|
| `no overload matches 'Punch::HTMLView#a' with types String, href: String` | [view_link_string](../../spec/fail/view_link_string.cr) |
| `` Punch::View: no `onclick`. Inline event handlers are blocked by the Content-Security-Policy `` | [view_event_handler](../../spec/fail/view_event_handler.cr) |
| `no overload matches 'Punch::HTMLView#img', src: String` | [view_img_string](../../spec/fail/view_img_string.cr) |
| `missing argument: alt` | [view_img_without_alt](../../spec/fail/view_img_without_alt.cr) |
| `` Punch::View: no `style`. Inline styles are blocked by the Content-Security-Policy `` | [view_inline_style](../../spec/fail/view_inline_style.cr) |
| `` Punch::View: `cite` takes a Punch::Href `` | [view_url_attribute](../../spec/fail/view_url_attribute.cr) |
| `` Punch::View: `id` takes a String, a number, a Bool, or a Time, not Array(Char) `` | [view_attribute_type](../../spec/fail/view_attribute_type.cr) |
| `'Punch::HTMLView#ul' is expected to be invoked with a block` | [view_text_in_list](../../spec/fail/view_text_in_list.cr) |
| `Notes::Show is a Page, so its name ends in Page, such as ShowPage.` | [page_name](../../spec/fail/page_name.cr) |
| `Notes::ListPage ends in Page but is a Query` | [query_named_page](../../spec/fail/query_named_page.cr) |
| `DestroyPage is not a page name` | [page_destroy](../../spec/fail/page_destroy.cr) |
| `Route collision: NotePage and Notes::ShowPage both answer GET /notes/:id` | [page_collision](../../spec/fail/page_collision.cr) |
| `Note is a page's result, but not a component and not a failure` | [page_result_data](../../spec/fail/page_result_data.cr) |
| `` Notes::IndexPage.href: unknown parameter `pages`. Parameters: page, tag `` | [href_unknown_param](../../spec/fail/href_unknown_param.cr) |
| `` Notes::IndexPage.href: missing parameter `tag` (String) `` | [href_missing_param](../../spec/fail/href_missing_param.cr) |
| `` Notes::IndexPage.href: `tag` is required and cannot be nil `` | [href_nil_required](../../spec/fail/href_nil_required.cr) |
| `` Notes::IndexPage.href: `page` must be Int32, not String `` | [href_wrong_type](../../spec/fail/href_wrong_type.cr) |
| `no overload matches 'Punch::View::Form(Notes::Create::Input)#field' with type Symbol` | [form_unknown_field](../../spec/fail/form_unknown_field.cr) |
| `Punch::View#form: no page holds the form of Notes::Create` | [form_without_page](../../spec/fail/form_without_page.cr) |
| `Notes::Create::Input#title must be String, not Int32` | [form_values_type](../../spec/fail/form_values_type.cr) |
| `` Notes::Create::Input has no field `titel` a form can fill. Fields: title `` | [form_values_unknown](../../spec/fail/form_values_unknown.cr) |
| `` Punch::View#form: Punch sets `id`; leave it out `` | [form_id_attribute](../../spec/fail/form_id_attribute.cr) |
| `` Punch writes `type` on form controls; leave it out `` | [form_control_attribute](../../spec/fail/form_control_attribute.cr) |
| `Notes::IndexPage and Notes::ListPage both hold its form` | [forms_two_pages](../../spec/fail/forms_two_pages.cr) |
| `` Its required field `template` cannot be filled from there `` | [forms_page_required_field](../../spec/fail/forms_page_required_field.cr) |
| `` Its path parameter `note_id` (Int64) is not one of Notes::Create's `` | [forms_page_path_param](../../spec/fail/forms_page_path_param.cr) |
| `Notes::Index is not a Command` | [forms_not_command](../../spec/fail/forms_not_command.cr) |
| `undefined method 'raw' for Punch::View` | [agent_page_raw](../../spec/fail/agent_page_raw.cr) |
| `Chart takes a Punch::HTMLView, so it may write raw HTML, and cannot render where only semantic elements are allowed` | [agent_page_html_view](../../spec/fail/agent_page_html_view.cr) |
| `Reports::Index: @[Punch::AgentReadable] marks pages that agents read as markdown; Reports::Index is not a page` | [agent_readable_query](../../spec/fail/agent_readable_query.cr) |
| `` Reports::ShowPage is an entry point in /llms.txt, so an agent opens it from its path alone. Its path parameter `report_id` cannot be filled from there `` | [agent_entry_path_param](../../spec/fail/agent_entry_path_param.cr) |
| `Reports::Index#live: only a page is live, and Reports::Index is not one` | [live_query](../../spec/fail/live_query.cr) |
| `` Reports::IndexPage#live takes the event first, its type stated, then what `call` takes: live(event : SomeEvent, input : Input, db : Punch::Reader) `` | [live_arity](../../spec/fail/live_arity.cr) |
| `` Reports::IndexPage#live takes (Reports::Changed \| Reports::Other): define one `live` per event type `` | [live_union](../../spec/fail/live_union.cr) |
| `Reports::IndexPage#live takes String, which is no event` | [live_not_event](../../spec/fail/live_not_event.cr) |

## Assets

Explained in [Assets](../assets.md).

| Message | Example |
|---|---|
| `Punch.asset: no asset "app.scss"` | [asset_unknown](../../spec/fail/asset_unknown.cr) |
| `Punch.assets: "page.html" has no extension Punch serves` | [asset_extension](../../spec/fail/asset_extension.cr) |
| `no overload matches 'Punch::HTMLView#document' with types String, stylesheets: Tuple(Punch::Asset::Static)` | [asset_stylesheet_type](../../spec/fail/asset_stylesheet_type.cr) |

## Translations

Explained in [Translations](../translations.md).

| Message | Example |
|---|---|
| `undefined method 'unread' for Fixture::Translations::Inbox` | [translation_unknown_key](../../spec/fail/translation_unknown_key.cr) |
| `missing argument: name` | [translation_missing_argument](../../spec/fail/translation_missing_argument.cr) |
| `` Fixture::Translations was generated with the default locale "en". Run `punch i18n:generate` `` | [translation_default_mismatch](../../spec/fail/translation_default_mismatch.cr) |

## Domain events

Explained in [Domain events](../events.md).

| Message | Example |
|---|---|
| `Notes::Index is a Query; only a Command publishes events` | [events_in_query](../../spec/fail/events_in_query.cr) |
| `Notes::Create#call takes Punch::Events(NoteAdded \| String), but String is not an event` | [events_not_event](../../spec/fail/events_not_event.cr) |
| `expected argument #1 to 'Punch::Events(NoteAdded)#publish' to be NoteAdded, not NoteRemoved` | [events_publish_undeclared](../../spec/fail/events_publish_undeclared.cr) |
| `NoteAdded includes Punch::Event, so it must be a struct` | [event_class](../../spec/fail/event_class.cr) |
| `NoteAdded#body=: an event is immutable, so it has no setters` | [event_setter](../../spec/fail/event_setter.cr) |
| `Mailer subscribes to String, which is no event` | [subscriber_not_event](../../spec/fail/subscriber_not_event.cr) |
| `` Projection is delivered inline, so it defines `call(event, db : Punch::Writer) : Nil` `` | [subscriber_inline_signature](../../spec/fail/subscriber_inline_signature.cr) |
| `` Projection is delivered after commit, so it defines `call(event) : Nil` `` | [subscriber_after_commit_with_db](../../spec/fail/subscriber_after_commit_with_db.cr) |
| `` Mailer is deferred, so it defines `call(event, job : Punch::Job::Context) : Punch::Job::Result` `` | [subscriber_deferred_signature](../../spec/fail/subscriber_deferred_signature.cr) |
| `Mailer has job options, but only a deferred subscriber runs as a job` | [subscriber_options_not_deferred](../../spec/fail/subscriber_options_not_deferred.cr) |
| `@[Punch::Job::Concurrency] on Mailer: by: :customer_id is not a field of NoteAdded` | [subscriber_concurrency_field](../../spec/fail/subscriber_concurrency_field.cr) |
| `` NoteForgotten is an event, so it defines `initialize`, also when it has no fields `` | [event_without_initialize](../../spec/fail/event_without_initialize.cr) |

## Background jobs

Explained in [Background jobs](../jobs.md).

| Message | Example |
|---|---|
| `Notes::Index is a Query; only a Command enqueues jobs` | [jobs_in_query](../../spec/fail/jobs_in_query.cr) |
| `Notes::Create#call takes Punch::Jobs(Remind \| String), but String is not a job` | [jobs_not_job](../../spec/fail/jobs_not_job.cr) |
| `no overload matches 'Punch::Jobs(Remind)#enqueue' with type Export` | [jobs_enqueue_undeclared](../../spec/fail/jobs_enqueue_undeclared.cr) |
| `Export includes Punch::Job, so it must be a struct` | [job_class](../../spec/fail/job_class.cr) |
| `` Export is a job, so it defines `perform(job : Punch::Job::Context) : Punch::Job::Result` `` | [job_without_perform](../../spec/fail/job_without_perform.cr) |
| `Export#perform returns String; a job returns Punch::Job::Result` | [job_perform_result](../../spec/fail/job_perform_result.cr) |
| `@[Punch::Job::Options] on Export: queue: is a name of lowercase letters, digits, and _` | [job_options_queue](../../spec/fail/job_options_queue.cr) |
| `@[Punch::Job::Options] on Export takes queue:, attempts:, and priority:, not retries:` | [job_options_unknown](../../spec/fail/job_options_unknown.cr) |
| `Report is recurring, so it runs with an empty payload; give Report#account_id a default or make it nilable` | [recurring_required_field](../../spec/fail/recurring_required_field.cr) |
| `@[Punch::Job::Recurring] on Report takes one of cron: "0 3 * * *" or every: 1.hour` | [recurring_two_schedules](../../spec/fail/recurring_two_schedules.cr) |
| `@[Punch::Job::Concurrency] on Report: by: :customer_id is not a field of the job` | [concurrency_unknown_field](../../spec/fail/concurrency_unknown_field.cr) |
| `` Export is a job, so it defines `initialize`, also when it has no fields `` | [job_without_initialize](../../spec/fail/job_without_initialize.cr) |
| `Export is not a job: a job is a struct that includes Punch::Job` | [job_enqueue_not_job](../../spec/fail/job_enqueue_not_job.cr) |
| `Export includes Punch::Job::Stepped, so it is a job: include Punch::Job too` | [steps_without_job](../../spec/fail/steps_without_job.cr) |
| `` Export runs in steps, so Punch defines `perform`, which runs them in order `` | [steps_with_perform](../../spec/fail/steps_with_perform.cr) |
| `Export includes Punch::Job::Stepped but marks no method @[Punch::Job::Step]` | [steps_none](../../spec/fail/steps_none.cr) |
| `` Export#copy is a step, so it takes `(job : Punch::Job::Context)`, or `(job : Punch::Job::Context, name : Punch::Job::Cursor(T))` `` | [step_signature](../../spec/fail/step_signature.cr) |
| `Export#copy returns String; a step returns Punch::Job::StepResult` | [step_result](../../spec/fail/step_result.cr) |
| `Export#copy is marked @[Punch::Job::Step], but Export does not run in steps: include Punch::Job::Stepped` | [step_without_steps](../../spec/fail/step_without_steps.cr) |
| `no overload matches 'Punch::Job::Cursor(Int64)#continue' with type String` | [step_cursor_type](../../spec/fail/step_cursor_type.cr) |
| `` Export::V1 is a frozen payload, so it defines `upgrade` with its return type `` | [payload_frozen_without_upgrade](../../spec/fail/payload_frozen_without_upgrade.cr) |
| `Export::V2#upgrade returns V1; it reads version 2 of Export, so it returns Export or the frozen type of a later version` | [payload_upgrade_backwards](../../spec/fail/payload_upgrade_backwards.cr) |
| `@[Punch::Payloads::Version] on Export: from: maps versions below 2 to frozen types; 2 is not one` | [payload_version_from_newer](../../spec/fail/payload_version_from_newer.cr) |
| `@[Punch::Payloads::Version] on Export: Export::V1 reads version 1, so it includes Punch::Payloads::Frozen` | [payload_from_not_frozen](../../spec/fail/payload_from_not_frozen.cr) |
| `Export is a stored payload, so it does not include JSON::Serializable::Strict` | [payload_strict](../../spec/fail/payload_strict.cr) |

## Mail

Explained in [Mail](../mail.md).

| Message | Example |
|---|---|
| `` abstract `def Punch::Mail#view(v : View)` must be implemented by Welcome `` | [mail_html_view](../../spec/fail/mail_html_view.cr) |
| `` abstract `def Punch::Mail#subject(locale : Locale)` must be implemented by Welcome `` | [mail_without_subject](../../spec/fail/mail_without_subject.cr) |

## Cache

Explained in [Cache](../cache.md).

| Message | Example |
|---|---|
| `Punch::Cache value holds Punch::Secret(String): secrets cannot be cached` | [cache_secret_value](../../spec/fail/cache_secret_value.cr) |
| `Punch::Cache key Float64: keys are String, Int32, Int64, Bool, an enum, a domain primitive, or a tuple of those` | [cache_key_type](../../spec/fail/cache_key_type.cr) |
| `Punch::Cache key (Int64 \| String) is a union` | [cache_key_union](../../spec/fail/cache_key_union.cr) |
| `ForgetBody forgets cache entries, which happens after commit: drop @[Punch::Subscriber::Delivery]` | [forget_with_delivery](../../spec/fail/forget_with_delivery.cr) |
| `` ForgetBody has @[Punch::Subscriber::Forget], so Punch writes its `call` `` | [forget_with_call](../../spec/fail/forget_with_call.cr) |
| `` @[Punch::Subscriber::Forget] on ForgetBody: NoteAdded has no `id` to take the key from `` | [forget_unknown_key](../../spec/fail/forget_unknown_key.cr) |
| `@[Punch::Subscriber::Forget] on ForgetBody: the key is String, but the store's keys are Int64` | [forget_key_type](../../spec/fail/forget_key_type.cr) |
| `Created includes Punch::HTTP::Versioned, so its status must be 200, not 201` | [versioned_status](../../spec/fail/versioned_status.cr) |

## Authentication

Explained in [Authentication](../auth.md).

| Message | Example |
|---|---|
| `Accounts::Peek is a Query; only a Command can sign in or out` | [auth_query_signs_in](../../spec/fail/auth_query_signs_in.cr) |
| `Accounts::Rename#call takes Int64, which is neither the app's actor` | [auth_unknown_parameter](../../spec/fail/auth_unknown_parameter.cr) |
| `` Accounts::Rename#call: give `actor` a type `` | [auth_untyped_parameter](../../spec/fail/auth_untyped_parameter.cr) |
| `` Member includes Punch::Auth::Actor, so it needs `def self.load `` | [auth_actor_without_load](../../spec/fail/auth_actor_without_load.cr) |
| `Accounts::Peek is a Query; only a Command checks a password` | [password_check_in_query](../../spec/fail/password_check_in_query.cr) |
| `` Accounts::SignIn takes Punch::Auth::PasswordCheck, so its input needs `getter email : Punch::Email` and `getter password : Punch::Auth::Password` `` | [password_check_fields](../../spec/fail/password_check_fields.cr) |
| `Accounts::SignIn checks passwords, so it needs a rate limit per account` | [password_check_without_limit](../../spec/fail/password_check_without_limit.cr) |
| `Punch::Auth::Password cannot be serialized to JSON` | [password_to_json](../../spec/fail/password_to_json.cr) |
| `Tokens::Index is a Query; a Command shows a secret once and the page after its form takes it, so only those take Punch::Auth::Reveal` | [reveal_query](../../spec/fail/reveal_query.cr) |
| `Tokens::Create takes Punch::Auth::Reveal, so it takes no idempotency key` | [reveal_idempotency](../../spec/fail/reveal_idempotency.cr) |
| `ChangePassword checks the user's password, so it needs a rate limit per user` | [own_password_check_without_limit](../../spec/fail/own_password_check_without_limit.cr) |
| `` SignIn checks passwords, so its `call` takes `events : Punch::Events(... \| Punch::Auth::SignInFailed)` `` | [password_check_without_failed_event](../../spec/fail/password_check_without_failed_event.cr) |
| `Complete checks second factors, so it needs a rate limit per user` | [second_factor_check_without_limit](../../spec/fail/second_factor_check_without_limit.cr) |
| `` Complete takes Punch::Auth::SecondFactorCheck, so its input needs `getter code : Punch::Auth::OneTimeCode` `` | [second_factor_check_without_code](../../spec/fail/second_factor_check_without_code.cr) |
| `` Complete takes Punch::Auth::SecondFactorCheck, so its `call` takes Punch::Auth::Authentication too `` | [second_factor_check_without_authentication](../../spec/fail/second_factor_check_without_authentication.cr) |
| `` Guess is limited by :challenge, so its `call` must take Punch::Auth::SecondFactorCheck `` | [challenge_limit_without_check](../../spec/fail/challenge_limit_without_check.cr) |
| `Reauthenticate checks the user's second factor, so it needs a rate limit per user` | [own_second_factor_check_without_limit](../../spec/fail/own_second_factor_check_without_limit.cr) |

## Authorization

Explained in [Authorization](../authorization.md).

| Message | Example |
|---|---|
| `` Notes::Archive is a Command with a policy, so its `call` must take `grant : Punch::Grant(Archive)` `` | [policy_command_without_grant](../../spec/fail/policy_command_without_grant.cr) |
| `Notes::Archive#call takes Punch::Grant(Notes::Purge), but a grant proves the policy of the operation it is given to` | [policy_grant_of_other](../../spec/fail/policy_grant_of_other.cr) |
| `Notes::Archive has no policy to make one` | [policy_grant_without_policy](../../spec/fail/policy_grant_without_policy.cr) |
| `` Notes::Index has a policy, so its `call` must take the app's actor `` | [policy_without_actor](../../spec/fail/policy_without_actor.cr) |
| `Notes::Index has @[Punch::Authorize] and @[Punch::Public]; keep one.` | [policy_and_public](../../spec/fail/policy_and_public.cr) |
| `private method 'new' called for Punch::Grant(O).class` | [policy_grant_forged](../../spec/fail/policy_grant_forged.cr) |
| `@[Punch::Authorize] on Notes::Index takes one policy` | [policy_two](../../spec/fail/policy_two.cr) |
| `@[Punch::Authorize(String)] names a type that is not a policy` | [policy_not_a_policy](../../spec/fail/policy_not_a_policy.cr) |
| `Reader includes Punch::Role but permits nothing` | [role_permits_nothing](../../spec/fail/role_permits_nothing.cr) |
| `Member permits Auditor, a role on everything (global), but Member is held on Teams::ID` | [role_other_scope](../../spec/fail/role_other_scope.cr) |
| `Member permits String, which is neither an operation nor a role` | [role_permits_other](../../spec/fail/role_permits_other.cr) |
| `Member is held on Teams::ID, not on Projects::ID` | [role_assign_wrong_resource](../../spec/fail/role_assign_wrong_resource.cr) |
| `` Member: `scope String` names a resource by its typed ID `` | [role_scope_not_id](../../spec/fail/role_scope_not_id.cr) |
| `` ByOwner.check takes `id`, but Billing::Invoices::Show has the path parameter `invoice_id` `` | [policy_keyword_mismatch](../../spec/fail/policy_keyword_mismatch.cr) |

## Credentials

Explained in [Credentials](../credentials.md).

| Message | Example |
|---|---|
| `Settings#hosts has type Array(String), which credentials cannot hold` | [credentials_unsupported_type](../../spec/fail/credentials_unsupported_type.cr) |
| `the group Settings#smtp cannot be optional` | [credentials_optional_group](../../spec/fail/credentials_optional_group.cr) |
| `Settings#smtp has type Punch::Secret(Settings::Smtp), which credentials cannot hold` | [credentials_secret_group](../../spec/fail/credentials_secret_group.cr) |
| `` Settings#signing_keys is a key ring; declare it as `getter secret_key_base : Punch::KeyRing` `` | [credentials_key_ring_name](../../spec/fail/credentials_key_ring_name.cr) |
| `` Settings#ids_key is the key of public IDs; declare it as `getter public_id_key : Punch::PublicIDKey` `` | [credentials_public_id_key_name](../../spec/fail/credentials_public_id_key_name.cr) |
| `Punch.credentials: 'Production' is not an environment name` | [credentials_environment_name](../../spec/fail/credentials_environment_name.cr) |

## Rate limits

Explained in [Rate limits](../rate-limits.md).

| Message | Example |
|---|---|
| `Accounts::SignIn is limited by :nickname, which is not :ip, :actor, :token, or a field of its input (email)` | [rate_limit_unknown_key](../../spec/fail/rate_limit_unknown_key.cr) |
| `` Accounts::SignIn is limited by :actor, so its `call` must take the app's actor `` | [rate_limit_actor_without_actor](../../spec/fail/rate_limit_actor_without_actor.cr) |
| `Accounts::SignIn has rate limits and @[Punch::RateLimitExempt]; keep one.` | [rate_limit_and_exempt](../../spec/fail/rate_limit_and_exempt.cr) |
| `` @[Punch::RateLimit] on Accounts::SignIn needs `per:` `` | [rate_limit_without_period](../../spec/fail/rate_limit_without_period.cr) |
| `@[Punch::RateLimitExempt] on Accounts::SignIn takes the reason` | [rate_limit_exempt_without_reason](../../spec/fail/rate_limit_exempt_without_reason.cr) |
| `Notes::Create is a Command that runs without a signed-in user, so it needs a rate limit` | [command_without_rate_limit](../../spec/fail/command_without_rate_limit.cr) |

## Uploads

Explained in [Uploads](../uploads.md).

| Message | Example |
|---|---|
| `Punch::Secret cannot be serialized to JSON` | [upload_private_file_to_json](../../spec/fail/upload_private_file_to_json.cr) |
| `Punch::Upload::PrivateFile holds a secret` | [upload_private_file_stored_dump](../../spec/fail/upload_private_file_stored_dump.cr) |
| `Punch: Scanned#state takes a Punch::Upload::ScanState` | [upload_scan_state_in_input](../../spec/fail/upload_scan_state_in_input.cr) |
| `Scan is a kind of upload, so it has @[Punch::Upload::Rules(max_size: 10_000_000` | [upload_kind_without_rules](../../spec/fail/upload_kind_without_rules.cr) |
| `@[Punch::Upload::Rules] on Page: Punch does not take "text/html"` | [upload_kind_html](../../spec/fail/upload_kind_html.cr) |
| `Punch: Detach#scan takes a Punch::Upload::Key, the key of a stored file` | [upload_key_in_input](../../spec/fail/upload_key_in_input.cr) |
| `@[Punch::Upload::Rules] on Photo: max_size: is the largest file in bytes, an integer literal` | [upload_kind_max_size](../../spec/fail/upload_kind_max_size.cr) |
