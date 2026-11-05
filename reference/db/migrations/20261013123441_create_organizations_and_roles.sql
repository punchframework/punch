-- Customers and invoices belong to an organization, and who may see or
-- change them follows from the roles users hold on it
-- (docs/authorization.md, "Roles"). The role tables and the view
-- `punch_permissions` are Punch's (`Punch::Roles::Schema.sql`).
--
-- A session or API token works in one organization at a time: the one
-- chosen last (`organization_choices`), else the first the user holds a
-- role on. Mail to a customer without a language goes out in the
-- organization's.
--
-- Every user who existed before gets an organization of their own, with
-- the same ID, their name and language, and is its administrator; their
-- customers and invoices move into it. Nothing released holds data yet, so the
-- owner column goes in this release.
-- rebuild: customers
-- rebuild: invoices
CREATE TABLE organizations (
  id         INTEGER PRIMARY KEY,
  name       TEXT    NOT NULL COLLATE de,
  locale     TEXT,
  created_at TEXT    NOT NULL
) STRICT;

INSERT INTO organizations (id, name, locale, created_at) SELECT id, name, locale, created_at FROM users;

CREATE TABLE organization_choices (
  id              INTEGER PRIMARY KEY,
  session_id      INTEGER UNIQUE REFERENCES punch_sessions (id) ON DELETE CASCADE,
  api_token_id    INTEGER UNIQUE REFERENCES punch_api_tokens (id) ON DELETE CASCADE,
  organization_id INTEGER NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
  CHECK ((session_id IS NULL) <> (api_token_id IS NULL))
) STRICT;

CREATE INDEX organization_choices_by_organization ON organization_choices (organization_id);

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

CREATE UNIQUE INDEX punch_role_assignments_unique
  ON punch_role_assignments (user_id, role, ifnull(resource_type, ''), ifnull(resource_id, 0));
CREATE INDEX punch_role_assignments_by_resource ON punch_role_assignments (resource_type, resource_id);

CREATE TABLE punch_role_operations (
  role      TEXT NOT NULL,
  operation TEXT NOT NULL,
  PRIMARY KEY (role, operation)
) STRICT, WITHOUT ROWID;

CREATE VIEW punch_permissions (user_id, operation, resource_type, resource_id, role) AS
  SELECT a.user_id, o.operation, a.resource_type, a.resource_id, a.role
  FROM punch_role_assignments a JOIN punch_role_operations o ON o.role = a.role
  WHERE (a.expires_at IS NULL OR a.expires_at > strftime('%Y-%m-%dT%H:%M:%S', 'now'));

INSERT INTO punch_role_assignments (user_id, role, resource_type, resource_id, created_at)
SELECT id, 'accounts.roles.administrator', 'accounts.organizations', id, created_at FROM users;

CREATE TABLE customers_new (
  id              INTEGER PRIMARY KEY,
  organization_id INTEGER NOT NULL REFERENCES organizations (id),
  name            TEXT    NOT NULL COLLATE de,
  company_name    TEXT,
  email           TEXT    NOT NULL,
  created_at      TEXT    NOT NULL,
  locale          TEXT,
  UNIQUE (organization_id, email),
  UNIQUE (organization_id, id)
) STRICT;

INSERT INTO customers_new (id, organization_id, name, company_name, email, created_at, locale)
SELECT id, owner_id, name, company_name, email, created_at, locale FROM customers;

DROP TABLE customers;
ALTER TABLE customers_new RENAME TO customers;

CREATE INDEX customers_by_name ON customers (organization_id, name);

CREATE TABLE invoices_new (
  id              INTEGER PRIMARY KEY,
  organization_id INTEGER NOT NULL,
  customer_id     INTEGER NOT NULL,
  currency        TEXT    NOT NULL,
  status          TEXT    NOT NULL,
  number          TEXT    UNIQUE,
  sent_at         TEXT,
  due_at          TEXT,
  created_at      TEXT    NOT NULL,
  FOREIGN KEY (organization_id, customer_id) REFERENCES customers (organization_id, id),
  CHECK (
    (status = 'draft' AND number IS NULL AND sent_at IS NULL AND due_at IS NULL) OR
    (status = 'sent' AND number IS NOT NULL AND sent_at IS NOT NULL AND due_at IS NOT NULL)
  )
) STRICT;

INSERT INTO invoices_new (id, organization_id, customer_id, currency, status, number, sent_at, due_at, created_at)
SELECT id, owner_id, customer_id, currency, status, number, sent_at, due_at, created_at FROM invoices;

DROP TABLE invoices;
ALTER TABLE invoices_new RENAME TO invoices;

CREATE INDEX invoices_by_organization ON invoices (organization_id, id);
CREATE INDEX invoices_by_customer ON invoices (customer_id, id);
