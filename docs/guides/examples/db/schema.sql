-- The complete schema, written by `punch db:migrate` after every migration.
-- Do not edit: change the schema with a new file in db/migrations.
CREATE TABLE id_scans (
  id                 INTEGER PRIMARY KEY,
  user_id            INTEGER NOT NULL REFERENCES users (id),
  photo_key          TEXT    NOT NULL,
  photo_filename     BLOB    NOT NULL,
  photo_size         INTEGER NOT NULL,
  photo_content_type TEXT    NOT NULL,
  photo_scan_state   TEXT,
  photo_delete_after TEXT,
  photo_width        INTEGER,
  photo_height       INTEGER,
  photo_alt          BLOB
) STRICT;

CREATE TABLE invoices (
  id             INTEGER PRIMARY KEY,
  number         TEXT    NOT NULL UNIQUE,
  customer_email TEXT    NOT NULL,
  due_at         TEXT    NOT NULL,
  paid_at        TEXT,
  reminded_at    TEXT
) STRICT;

CREATE TABLE logos (
  id                 INTEGER PRIMARY KEY,
  user_id            INTEGER NOT NULL REFERENCES users (id),
  image_key          TEXT    NOT NULL,
  image_filename     TEXT    NOT NULL,
  image_size         INTEGER NOT NULL,
  image_content_type TEXT    NOT NULL,
  image_scan_state   TEXT,
  image_delete_after TEXT,
  image_width        INTEGER,
  image_height       INTEGER,
  image_alt          TEXT
) STRICT;

CREATE TABLE paid_counts (
  id             INTEGER PRIMARY KEY,
  customer_email TEXT    NOT NULL UNIQUE,
  invoices       INTEGER NOT NULL
) STRICT;

CREATE TABLE payment_methods (
  id             INTEGER PRIMARY KEY,
  customer_email TEXT    NOT NULL,
  method         TEXT    NOT NULL CHECK (json_valid(method) AND json_type(method) = 'object')
) STRICT;

CREATE TABLE products (
  id      INTEGER PRIMARY KEY,
  name    TEXT    NOT NULL UNIQUE,
  pricing TEXT    NOT NULL CHECK (json_valid(pricing) AND json_type(pricing) = 'object')
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

CREATE TABLE punch_uploads (
  id            TEXT    NOT NULL PRIMARY KEY,
  ticket_digest BLOB    NOT NULL UNIQUE,
  kind          TEXT    NOT NULL,
  owner         TEXT    NOT NULL,
  size          INTEGER NOT NULL,
  content_type  TEXT    NOT NULL,
  state         TEXT    NOT NULL CHECK (state IN ('granted', 'checking', 'checked', 'claimed', 'discarded')),
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER,
  claimed_at    INTEGER,
  checking_since INTEGER
, filename TEXT) STRICT, WITHOUT ROWID;

CREATE TABLE receipts (
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users (id),
  description TEXT    NOT NULL,
  file_key        TEXT    NOT NULL,
  file_size   INTEGER NOT NULL,
  file_content_type   TEXT    NOT NULL,
  created_at  TEXT    NOT NULL
, file_filename TEXT NOT NULL DEFAULT 'scan', file_scan_state TEXT, file_delete_after TEXT) STRICT;

CREATE TABLE statements (
  id                INTEGER PRIMARY KEY,
  user_id           INTEGER NOT NULL REFERENCES users (id),
  file_key          TEXT    NOT NULL,
  file_filename     BLOB    NOT NULL,
  file_size         INTEGER NOT NULL,
  file_content_type TEXT    NOT NULL,
  created_at        TEXT    NOT NULL
, file_scan_state TEXT, file_delete_after TEXT) STRICT;

CREATE TABLE users (
  id         INTEGER PRIMARY KEY,
  name       TEXT    NOT NULL,
  created_at TEXT    NOT NULL,
  locale     TEXT
) STRICT;

CREATE INDEX id_scans_by_user ON id_scans (user_id);

CREATE INDEX invoices_unpaid ON invoices (due_at) WHERE paid_at IS NULL;

CREATE INDEX logos_by_user ON logos (user_id);

CREATE INDEX payment_methods_customer ON payment_methods (customer_email);

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

CREATE INDEX punch_uploads_owner ON punch_uploads (owner, state, expires_at);

CREATE INDEX punch_uploads_sweep ON punch_uploads (expires_at) WHERE expires_at IS NOT NULL;

CREATE INDEX receipts_by_user ON receipts (user_id);

CREATE INDEX statements_by_user ON statements (user_id);

CREATE VIEW punch_permissions (user_id, operation, resource_type, resource_id, role) AS
  SELECT a.user_id, o.operation, a.resource_type, a.resource_id, a.role
  FROM punch_role_assignments a JOIN punch_role_operations o ON o.role = a.role
  WHERE (a.expires_at IS NULL OR a.expires_at > strftime('%Y-%m-%dT%H:%M:%S', 'now'));

INSERT INTO punch_schema_migrations (version, name, checksum) VALUES
  (20261023000000, 'create_users', 'be88d1be85dab70a781a98e12a87cca1026657abb674cb36e1e090f18a5cac9b'),
  (20261023000100, 'add_punch_auth', '27a49a61ff2488f0cc4844b8339b3f6038f9ab30a42165ce08b5717a0dd13b57'),
  (20261023000200, 'add_punch_roles', 'cbcc7f34b42da7f6fc39934f278db524dcaae645640ce8416c64f42dd8650e86'),
  (20261023000300, 'add_punch_outbox', 'ad12098785bc998f9abbcc300c7aa7b98694bc12396c40348458e4cfa875c437'),
  (20261023000350, 'add_punch_steps', '19354f78734cf9b3a0eceb9ca2f947eb07aa95aaead8656a560410fc5526b854'),
  (20261023000400, 'add_punch_idempotency', '18101680a6f9fe08b317a26bc53910fd197bf01def774ceb890c4e2e82e28613'),
  (20261023133847, 'create_invoices', '9ddfc59e1a1dcc82442c7060f4f3fb7da58b1896fc1092be5627da8422aa9c60'),
  (20261102201205, 'create_products', 'c6e59516c64648e268c74b0a49fba93f216f309f1930a8144013cbbb566a3958'),
  (20261102201206, 'create_payment_methods', 'df3f3c0bd874b9a2286b573934e48888eef6a76b5bd3ef0263b838225f90b046'),
  (20261102234321, 'create_paid_counts', 'f8651a1b8ff7ec4e3dd8cf811d9deb4b48a92f68370244e6be510f12846fd692'),
  (20261104195614, 'add_punch_uploads', '5eacd05eb7a8017f22a2f65eed1096fb339274e667d2d431cae19831e0293d6f'),
  (20261104195700, 'create_receipts', '11668457d43b7ad0ce3971d6ac788d7084c7dd03a1a9ff1e00c52042eebf2e10'),
  (20261104210000, 'add_filename_to_punch_uploads', '321d42aa96d69ac5bf3e118309f3d7e0b764cab6df6e5ca6a7cb27fd5db99ad4'),
  (20261104210100, 'add_scan_name_to_receipts', 'cbe9fdaafad6f8acc8e9bf4e39170b83230cd3213f76a7dc7c017e0e6fe97bd6'),
  (20261104220000, 'keep_receipt_scans_as_a_group', 'ebda48aa4386c2bce2edc538b6e31256cd4ac8dd42f1fbe464410df201ef69ae'),
  (20261104220100, 'create_statements', '2e67f66a1508dd6804f0afa28923dd02bd3678e5a78e6f011d100275490f234a'),
  (20261104230000, 'add_scan_state_and_delete_after_to_files', '32e4eb93b9b3ec48bfab635f5e69d9b6e531610c80d17a27fcc126f979262eb1'),
  (20261104230100, 'create_logos_and_id_scans', '1c402f33e66b23282ba20adac860ac914a0fdd35da4c02431ed51e4faef763c7');
