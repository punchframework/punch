-- The complete schema, written by `punch db:migrate` after every migration.
-- Do not edit: change the schema with a new file in db/migrations.
CREATE TABLE billing_profiles (
  organization_id     INTEGER PRIMARY KEY REFERENCES organizations (id),
  address_street      TEXT    NOT NULL,
  address_postal_code TEXT    NOT NULL,
  address_city        TEXT    NOT NULL,
  address_country     TEXT    NOT NULL,
  updated_at          TEXT    NOT NULL
) STRICT;

CREATE TABLE "customers" (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  organization_id INTEGER NOT NULL REFERENCES organizations (id),
  name            TEXT    NOT NULL COLLATE de,
  company_name    TEXT,
  created_at      TEXT    NOT NULL,
  locale          TEXT,
  address         BLOB,
  tax_id          BLOB,
  tax_id_index    BLOB,
  email_encrypted BLOB    NOT NULL,
  email_index     BLOB    NOT NULL,
  UNIQUE (organization_id, id)
) STRICT;

CREATE TABLE invoice_lines (
  id          INTEGER PRIMARY KEY,
  invoice_id  INTEGER NOT NULL REFERENCES invoices (id) ON DELETE CASCADE,
  position    INTEGER NOT NULL,
  description TEXT    NOT NULL,
  quantity    INTEGER NOT NULL CHECK (quantity > 0),
  unit_price  INTEGER NOT NULL,
  UNIQUE (invoice_id, position)
) STRICT;

CREATE TABLE invoice_payments (
  invoice_id INTEGER PRIMARY KEY REFERENCES invoices (id),
  -- The provider's ID of the payment.
  reference  TEXT    NOT NULL,
  amount     INTEGER NOT NULL,
  paid_at    TEXT    NOT NULL
) STRICT;

CREATE TABLE invoice_reminders (
  invoice_id INTEGER PRIMARY KEY REFERENCES invoices (id) ON DELETE CASCADE,
  created_at TEXT    NOT NULL
) STRICT;

CREATE TABLE "invoices" (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  organization_id INTEGER NOT NULL,
  customer_id     INTEGER NOT NULL,
  currency        TEXT    NOT NULL,
  status          TEXT    NOT NULL,
  number          TEXT    UNIQUE,
  sent_at         TEXT,
  due_at          TEXT,
  created_at      TEXT    NOT NULL, billed_to BLOB,
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  CHECK (
    (status = 'draft' AND number IS NULL AND sent_at IS NULL AND due_at IS NULL) OR
    (status = 'sent' AND number IS NOT NULL AND sent_at IS NOT NULL AND due_at IS NOT NULL)
  )
) STRICT;

CREATE TABLE organization_choices (
  id              INTEGER PRIMARY KEY,
  session_id      INTEGER UNIQUE REFERENCES punch_sessions (id) ON DELETE CASCADE,
  api_token_id    INTEGER UNIQUE REFERENCES punch_api_tokens (id) ON DELETE CASCADE,
  organization_id INTEGER NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  CHECK ((session_id IS NULL) <> (api_token_id IS NULL))
) STRICT;

CREATE TABLE organizations (
  id         INTEGER PRIMARY KEY,
  name       TEXT    NOT NULL COLLATE de,
  locale     TEXT,
  created_at TEXT    NOT NULL
) STRICT;

CREATE TABLE punch_api_tokens (
  id           INTEGER PRIMARY KEY,
  token_hash   BLOB    NOT NULL UNIQUE,
  user_id      INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  name         TEXT    NOT NULL,
  created_at   TEXT    NOT NULL,
  expires_at   TEXT    NOT NULL,
  last_used_at TEXT
) STRICT;

CREATE TABLE punch_collations (name TEXT PRIMARY KEY, version TEXT NOT NULL) STRICT;

CREATE TABLE punch_email_identities (
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  email       TEXT    NOT NULL UNIQUE,
  verified_at TEXT,
  created_at  TEXT    NOT NULL
) STRICT;

CREATE TABLE punch_idempotency_keys (
  scope        TEXT    NOT NULL,
  operation    TEXT    NOT NULL,
  key          TEXT    NOT NULL,
  fingerprint  BLOB    NOT NULL,
  status       INTEGER NOT NULL,
  content_type TEXT,
  location     TEXT,
  body         BLOB    NOT NULL,
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  PRIMARY KEY (scope, operation, key)
) STRICT, WITHOUT ROWID;

CREATE TABLE punch_job_progress (
  key         TEXT    PRIMARY KEY,
  type        TEXT    NOT NULL,
  step        TEXT,
  cursor      TEXT,
  saves       INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  finished_at INTEGER
) STRICT, WITHOUT ROWID;

CREATE TABLE punch_one_time_tokens (
  token_hash BLOB    PRIMARY KEY,
  purpose    TEXT    NOT NULL,
  user_id    INTEGER REFERENCES users (id) ON DELETE CASCADE,
  subject    TEXT,
  created_at TEXT    NOT NULL,
  expires_at TEXT    NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE punch_outbox (
  id                INTEGER PRIMARY KEY,
  key               TEXT    NOT NULL UNIQUE,
  queue             TEXT    NOT NULL,
  type              TEXT    NOT NULL,
  version           INTEGER NOT NULL,
  payload           TEXT    NOT NULL,
  priority          INTEGER NOT NULL,
  run_at            INTEGER NOT NULL,
  max_attempts      INTEGER NOT NULL,
  concurrency_key   TEXT,
  concurrency_limit INTEGER,
  traceparent       TEXT,
  created_at        INTEGER NOT NULL,
  handed_over_at    INTEGER
) STRICT;

CREATE TABLE punch_passwords (
  user_id    INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  hash       TEXT    NOT NULL,
  created_at TEXT    NOT NULL,
  updated_at TEXT    NOT NULL
) STRICT;

CREATE TABLE punch_recovery_codes (
  code_hash  BLOB    PRIMARY KEY,
  user_id    INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TEXT    NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE punch_role_assignments (
  id            INTEGER PRIMARY KEY,
  user_id       INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  role          TEXT    NOT NULL,
  resource_type TEXT,
  resource_id   INTEGER,
  expires_at    TEXT,
  assigned_by   INTEGER REFERENCES users (id) ON DELETE SET NULL,
  created_at    TEXT    NOT NULL,
  CHECK ((resource_type IS NULL) = (resource_id IS NULL))
) STRICT;

CREATE TABLE punch_role_operations (
  role      TEXT NOT NULL,
  operation TEXT NOT NULL,
  PRIMARY KEY (role, operation)
) STRICT, WITHOUT ROWID;

CREATE TABLE punch_schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  checksum TEXT NOT NULL,
  applied_at TEXT
) STRICT;

CREATE TABLE punch_sessions (
  id               INTEGER PRIMARY KEY,
  token_hash       BLOB    NOT NULL UNIQUE,
  user_id          INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  method           TEXT    NOT NULL,
  authenticated_at TEXT    NOT NULL,
  created_at       TEXT    NOT NULL,
  last_seen_at     TEXT    NOT NULL,
  expires_at       TEXT    NOT NULL,
  ip               TEXT,
  user_agent       TEXT
) STRICT;

CREATE TABLE punch_totp_authenticators (
  user_id      INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  secret       BLOB    NOT NULL,
  confirmed_at TEXT,
  last_step    INTEGER NOT NULL,
  unseen_codes BLOB,
  created_at   TEXT    NOT NULL
) STRICT;

CREATE TABLE punch_webhooks (
  id          INTEGER PRIMARY KEY,
  provider    TEXT    NOT NULL,
  key         TEXT    NOT NULL,
  fingerprint BLOB    NOT NULL,
  state       TEXT    NOT NULL,
  body        BLOB    NOT NULL,
  headers     TEXT    NOT NULL,
  attempts    INTEGER NOT NULL,
  error       TEXT,
  received_at INTEGER NOT NULL,
  verified_at INTEGER,
  finished_at INTEGER,
  UNIQUE (provider, key)
) STRICT;

CREATE TABLE users (
  id         INTEGER PRIMARY KEY,
  name       TEXT    NOT NULL,
  created_at TEXT    NOT NULL
, locale TEXT) STRICT;

CREATE UNIQUE INDEX customers_by_email_index ON customers (organization_id, email_index);

CREATE INDEX customers_by_name ON customers (organization_id, name);

CREATE UNIQUE INDEX customers_by_tax_id ON customers (organization_id, tax_id_index);

CREATE INDEX invoices_by_customer ON invoices (customer_id, id);

CREATE INDEX invoices_by_organization ON invoices (organization_id, id);

CREATE INDEX invoices_sent_by_id ON invoices (id, due_at) WHERE status = 'sent';

CREATE INDEX organization_choices_by_organization ON organization_choices (organization_id);

CREATE INDEX punch_api_tokens_by_user ON punch_api_tokens (user_id);

CREATE INDEX punch_email_identities_by_user ON punch_email_identities (user_id);

CREATE INDEX punch_idempotency_keys_expiry ON punch_idempotency_keys (expires_at);

CREATE INDEX punch_job_progress_finished ON punch_job_progress (finished_at) WHERE finished_at IS NOT NULL;

CREATE INDEX punch_one_time_tokens_by_user ON punch_one_time_tokens (user_id, purpose);

CREATE INDEX punch_outbox_handed_over ON punch_outbox (handed_over_at) WHERE handed_over_at IS NOT NULL;

CREATE INDEX punch_outbox_pending ON punch_outbox (id) WHERE handed_over_at IS NULL;

CREATE INDEX punch_recovery_codes_by_user ON punch_recovery_codes (user_id);

CREATE INDEX punch_role_assignments_by_resource ON punch_role_assignments (resource_type, resource_id);

CREATE UNIQUE INDEX punch_role_assignments_unique
  ON punch_role_assignments (user_id, role, ifnull(resource_type, ''), ifnull(resource_id, 0));

CREATE INDEX punch_sessions_by_user ON punch_sessions (user_id);

CREATE INDEX punch_webhooks_by_state ON punch_webhooks (provider, state);

CREATE INDEX punch_webhooks_finished ON punch_webhooks (finished_at) WHERE finished_at IS NOT NULL;

CREATE VIEW punch_permissions (user_id, operation, resource_type, resource_id, role) AS
  SELECT a.user_id, o.operation, a.resource_type, a.resource_id, a.role
  FROM punch_role_assignments a JOIN punch_role_operations o ON o.role = a.role
  WHERE (a.expires_at IS NULL OR a.expires_at > strftime('%Y-%m-%dT%H:%M:%S', 'now'));

INSERT INTO punch_schema_migrations (version, name, checksum) VALUES
  (20261008200000, 'create_customers', '616f2e7048b8d526625287fb7ad1353b8e53fa55f11647bac77f724b6b8276db'),
  (20261008200100, 'create_invoices', '38a1a5aedd0f4575004f0debf12e84dcd5f9020eccc726dfa141fbfaf194ad3b'),
  (20261009090000, 'sort_customer_names', '9b1d559fcb26acd255511bcc18a17fda4dd0ebb71f32281a82ac361915ca3f72'),
  (20261009120000, 'create_users_and_sessions', '6f0a7a3b7f1cb968ae3fd21ec37c4aad3ccb45513254d8bdb9cf30a174017972'),
  (20261009180000, 'create_identities_and_passwords', 'b628809e574d8905d10fc97ce9bb4292d15b68b47ddc07a2125070e81096ee64'),
  (20261009210000, 'add_owners', '83fe7dca652a7ea1282262f6b2cea9108d71bc3112b1df0bd121c420c31ffe3a'),
  (20261011090000, 'create_outbox_and_reminders', 'a94372349c661a47e41df785a04e0176cb3aa2475a900da13d83992b2592246a'),
  (20261012090000, 'create_invoice_payments', '5db1d04751f66a639e8bf621d2448e7e8757abbed95c1458e3370b30db51571f'),
  (20261012100000, 'add_user_locale', '6435850db4edd4041f1fd3fea998c4ee6019aeed28c264560370e3faeb634db8'),
  (20261012110323, 'add_customer_locale', '3f1e4fc5a376295cd97767d37b93f9350c3bbb671410885bd7ebd12df4e7a161'),
  (20261012131158, 'create_idempotency_keys', '16f0c5e67862697c3e2180b3b4a0f74c8463514e707dca5179cfc6675aa4252c'),
  (20261012132603, 'create_webhooks', '9df5f2ed958601bfaa964d4407866f27f9640c8279531c5b3e0af645067e65ab'),
  (20261013110135, 'create_second_factors', '54a9624037be4947ad60f0b30491227e864934e32709cac73ac7149606c1d49f'),
  (20261013123441, 'create_organizations_and_roles', 'cf1bc1d86a11c3036765bdf5ff37fb63ed38c6fcbd5a5812817ddad77aaffc49'),
  (20261023064356, 'rename_accountant_to_editor', 'e3681f4c80036a60999cbe834f8395a2dfd7fe23a470dbf6387490347d5f4e09'),
  (20261030120000, 'add_address_to_customers', 'a86f497d9b2ab3e1b4be8de73914a0523a56797a84c0bca5cf24d4796b75540d'),
  (20261030204159, 'add_tax_id_to_customers', '4eee1608f46f6549b825c65848f9dd92d9c8b690394b2ca1139ba71fbf926124'),
  (20261030214641, 'encrypt_customer_emails', '002ff27bd8afc3f1f1be30d60c9f7ebabed37a0457d7df2d9312147f9a1cbcc1'),
  (20261030221650, 'clear_customer_emails', '0de1a3f71bfb4e85109f02e1099a2af7c27a67570db8e7451d6f054d69aade02'),
  (20261030221929, 'drop_customer_plaintext_emails', '5235e4efec7b0358efe35b11d1e1faada36aa42eb0356e9f2d437a07f8114ed2'),
  (20261101195850, 'add_punch_steps', '19354f78734cf9b3a0eceb9ca2f947eb07aa95aaead8656a560410fc5526b854'),
  (20261101201456, 'index_sent_invoices', 'd2bfee856948046b6c569f3b7ab5aa82c10fb0d8d6d093ab3fe8f55cbf8e78e7'),
  (20261102160000, 'autoincrement_invoices_and_customers', '34b6d88d007d342373942e8c6fd8462ee013a6457578637b27726d3f1e5bd7f1'),
  (20261102183822, 'add_invoice_billed_to', 'b66c8fe339bb296c5ca5680d2764492474c7376aae388db967f0ea643825f703'),
  (20261102191115, 'create_billing_profiles', '406176f379136daa45accf4962a79e9f96d37bcc643a0422422e4d49dcf27eeb');
INSERT INTO punch_collations (name, version) VALUES
  ('de', 'punch-latin-1/unicode-17.0.0');
