-- Invoices and customers have public IDs (`public_id` in their types.cr,
-- lib/punch/docs/core-types.md), so their rowids must never be handed
-- out twice: without AUTOINCREMENT, SQLite gives the rowid of a deleted
-- last row to the next row, and an old link would lead to a new record.
-- SQLite cannot add AUTOINCREMENT in place. Copying the rows starts each
-- table's sqlite_sequence entry at its highest rowid.
-- rebuild: customers
-- rebuild: invoices
CREATE TABLE customers_new (
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

INSERT INTO customers_new (id, organization_id, name, company_name, created_at, locale, address, tax_id, tax_id_index, email_encrypted, email_index)
SELECT id, organization_id, name, company_name, created_at, locale, address, tax_id, tax_id_index, email_encrypted, email_index FROM customers;

DROP TABLE customers;
ALTER TABLE customers_new RENAME TO customers;

CREATE UNIQUE INDEX customers_by_email_index ON customers (organization_id, email_index);
CREATE INDEX customers_by_name ON customers (organization_id, name);
CREATE UNIQUE INDEX customers_by_tax_id ON customers (organization_id, tax_id_index);

CREATE TABLE invoices_new (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
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
SELECT id, organization_id, customer_id, currency, status, number, sent_at, due_at, created_at FROM invoices;

DROP TABLE invoices;
ALTER TABLE invoices_new RENAME TO invoices;

CREATE INDEX invoices_by_customer ON invoices (customer_id, id);
CREATE INDEX invoices_by_organization ON invoices (organization_id, id);
CREATE INDEX invoices_sent_by_id ON invoices (id, due_at) WHERE status = 'sent';
