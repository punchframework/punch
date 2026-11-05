-- The complete schema, written by `punch db:migrate` after every migration.
-- Do not edit: change the schema with a new file in db/migrations.

CREATE TABLE accounts (
  id         INTEGER PRIMARY KEY,
  name       TEXT    NOT NULL,
  plan       TEXT    NOT NULL DEFAULT 'free',
  created_at TEXT    NOT NULL
) STRICT;

CREATE TABLE customers (
  id           INTEGER PRIMARY KEY,
  account_id   INTEGER NOT NULL REFERENCES accounts (id),
  name         TEXT    NOT NULL,
  email        TEXT    NOT NULL,
  company_name TEXT,
  vat_id       TEXT,
  active       INTEGER NOT NULL DEFAULT 1,
  archived_at  TEXT,
  UNIQUE (account_id, email)
) STRICT;

-- Encrypted columns: ciphertext in BLOBs.
CREATE TABLE contacts (
  id          INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers (id),
  phone       BLOB    NOT NULL,
  note        BLOB,
  born        BLOB,
  vip         BLOB,
  phone_index BLOB    NOT NULL,
  UNIQUE (customer_id, phone_index)
) STRICT;

-- Plaintext columns being converted: leads in the first release
-- (from(:email)), prospects in the second (clear: true).
CREATE TABLE leads (
  id              INTEGER PRIMARY KEY,
  email           TEXT NOT NULL,
  email_encrypted BLOB,
  email_index     BLOB,
  UNIQUE (email_index)
) STRICT;

CREATE TABLE prospects (
  id              INTEGER PRIMARY KEY,
  name            TEXT NOT NULL,
  email           TEXT,
  email_encrypted BLOB
) STRICT;

CREATE TABLE invoice_lines (
  id               INTEGER PRIMARY KEY,
  invoice_id       INTEGER NOT NULL REFERENCES invoices (id) ON DELETE CASCADE,
  position         INTEGER NOT NULL,
  description      TEXT    NOT NULL,
  quantity         REAL    NOT NULL,
  unit_price_cents INTEGER NOT NULL
) STRICT;

CREATE TABLE invoices (
  id          INTEGER PRIMARY KEY,
  account_id  INTEGER NOT NULL REFERENCES accounts (id),
  customer_id INTEGER NOT NULL REFERENCES customers (id),
  number      TEXT    NOT NULL,
  status      TEXT    NOT NULL DEFAULT 'draft',
  issued_on   TEXT,
  due_on      TEXT,
  sent_at     TEXT,
  total_cents INTEGER NOT NULL DEFAULT 0,
  note        TEXT,
  created_at  TEXT    NOT NULL,
  UNIQUE (account_id, number)
) STRICT;

CREATE TABLE payments (
  id           INTEGER PRIMARY KEY,
  invoice_id   INTEGER NOT NULL REFERENCES invoices (id),
  amount_cents INTEGER NOT NULL,
  paid_at      TEXT    NOT NULL,
  reference    TEXT,
  raw          BLOB
) STRICT;

CREATE TABLE settings (
  account_id INTEGER NOT NULL REFERENCES accounts (id),
  "key"      TEXT    NOT NULL,
  value      TEXT    NOT NULL,
  PRIMARY KEY (account_id, "key")
) STRICT, WITHOUT ROWID;

CREATE INDEX invoices_customer ON invoices (customer_id, created_at);


-- Rules triggers enforce, which Punch.violation makes values: a pro account
-- keeps its plan (409), and an account has a name (422 at name).
CREATE TRIGGER accounts_plan_locked BEFORE UPDATE OF plan ON accounts
WHEN OLD.plan = 'pro'
BEGIN SELECT RAISE(ABORT, 'punch:plan_locked'); END;

CREATE TRIGGER accounts_named BEFORE INSERT ON accounts
WHEN NEW.name = ''
BEGIN SELECT RAISE(ABORT, 'punch:name_blank'); END;

-- Composites (docs/composites.md): groups of columns on sites, JSON
-- documents on orders, with generated columns over paths.
CREATE TABLE sites (
  id                  INTEGER PRIMARY KEY,
  account_id          INTEGER NOT NULL REFERENCES accounts (id),
  name                TEXT    NOT NULL,
  address_street      TEXT    NOT NULL,
  address_city        TEXT    NOT NULL,
  address_country     TEXT    NOT NULL DEFAULT 'DE',
  address_geo_lat     REAL,
  address_geo_lng     REAL,
  billing_street      TEXT,
  billing_city        TEXT,
  billing_country     TEXT,
  billing_geo_lat     REAL,
  billing_geo_lng     REAL,
  contact_name        TEXT    NOT NULL,
  contact_phone       BLOB,
  contact_phone_index BLOB,
  CHECK ((address_geo_lat IS NULL) + (address_geo_lng IS NULL) IN (0, 2)),
  CHECK ((billing_street IS NULL) + (billing_city IS NULL) + (billing_country IS NULL) IN (0, 3)
    AND (billing_street IS NOT NULL OR (billing_geo_lat IS NULL AND billing_geo_lng IS NULL))),
  CHECK ((billing_geo_lat IS NULL) + (billing_geo_lng IS NULL) IN (0, 2))
) STRICT;

CREATE INDEX sites_city ON sites (account_id, address_city);

CREATE TABLE orders (
  id           INTEGER PRIMARY KEY,
  account_id   INTEGER NOT NULL REFERENCES accounts (id),
  shipping     TEXT    NOT NULL CHECK (json_valid(shipping) AND json_type(shipping) = 'object'),
  billed_to    BLOB,
  payment      TEXT    CHECK (payment IS NULL OR (json_valid(payment) AND json_type(payment) = 'object')),
  ship_city    TEXT    GENERATED ALWAYS AS (shipping ->> '$.address.city') VIRTUAL,
  payment_kind TEXT    GENERATED ALWAYS AS (json_extract(payment, '$.kind')) VIRTUAL
) STRICT;

CREATE INDEX orders_ship_city ON orders (account_id, ship_city);
