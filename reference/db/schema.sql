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
  (20261009090000, 'sort_customer_names', '666250dae521edd49ca50a0b089974984c48fc13bf2967b72aa2eb5bf01ffc9b'),
  (20261009120000, 'create_users_and_sessions', '40d05da3ca96bf44705f84f682763f42d03f74044ccc13f19cf4a5fb2aa49d05'),
  (20261009180000, 'create_identities_and_passwords', 'b5ac4ff33e4f7e6a238812a740efa2ab1aa3f1160a4309a068ff3b8984921646'),
  (20261009210000, 'add_owners', 'e9d649b3a617e7afcba64e3c4722d69eb5a458ed466dbed2bd43a5b603fd75e2'),
  (20261011090000, 'create_outbox_and_reminders', '9f6b073df404d083b824705c78cdbcd98ced0b1b3388daec6c6092afd8cb0b7b'),
  (20261012090000, 'create_invoice_payments', '583b2c5f087f2b60193a917f31c571168a00bcc9c700c5c50db41942ab6349b1'),
  (20261012100000, 'add_user_locale', '81ea39421e8d75f4d4f7a656b43c9df4693ad721492f0720e10ad830c7fe36a6'),
  (20261012110323, 'add_customer_locale', 'bd5c653ffdaeae9080fe7ec6d16be34a69da771b5815b82900ecffa953eb0a6f'),
  (20261012131158, 'create_idempotency_keys', '071a531dc6b87d8f0772b580f9b7839401b8a772446af679000f6547484b482c'),
  (20261012132603, 'create_webhooks', 'd25d71f204ee8533e66a84f59bf23d4a1e5a1633fcf02f72ff8d91b2fc365d04'),
  (20261013110135, 'create_second_factors', '986cb0dbdc16b0c0393a5ab6f38543fd12049ca62ddc8a13e4f4a6badadc4e03'),
  (20261013123441, 'create_organizations_and_roles', '227cddd6a92094f4c57ee9fd84855e751705bef4cb231e854e754ad1546672fa'),
  (20261023064356, 'rename_accountant_to_editor', 'ed19f40c38cd6bc3fbafa27abbfbb05af11a369ce3ab696b5f265b7a4d7f23b7'),
  (20261030120000, 'add_address_to_customers', '40de65d6725365edf9a5b81c26936a537b9adcc747c6b8d435b7febdf7a2d234'),
  (20261030204159, 'add_tax_id_to_customers', '675e37b0c7f2b930e256ea7421a52db376c85be2050951b24699c1c529bc2a5e'),
  (20261030214641, 'encrypt_customer_emails', 'ae8c287f8fe80f43295c536026f8a363bf0d3c9f758e3c82b378ef39361bf214'),
  (20261030221650, 'clear_customer_emails', 'ce81341949004dca9b5033089ea1daadb2976919fa71516fa88bb724e8baff2c'),
  (20261030221929, 'drop_customer_plaintext_emails', 'a3194b1a59fa8bc96987ce69357579e995144cd0c7183440e1bd8e7737f29407'),
  (20261101195850, 'add_punch_steps', '19354f78734cf9b3a0eceb9ca2f947eb07aa95aaead8656a560410fc5526b854'),
  (20261101201456, 'index_sent_invoices', 'd2bfee856948046b6c569f3b7ab5aa82c10fb0d8d6d093ab3fe8f55cbf8e78e7'),
  (20261102160000, 'autoincrement_invoices_and_customers', '34b6d88d007d342373942e8c6fd8462ee013a6457578637b27726d3f1e5bd7f1'),
  (20261102183822, 'add_invoice_billed_to', 'b66c8fe339bb296c5ca5680d2764492474c7376aae388db967f0ea643825f703'),
  (20261102191115, 'create_billing_profiles', '406176f379136daa45accf4962a79e9f96d37bcc643a0422422e4d49dcf27eeb');
INSERT INTO punch_collations (name, version) VALUES
  ('de', 'punch-latin-1/unicode-17.0.0');
