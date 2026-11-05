-- Converting customers.email, second of three releases: the plaintext
-- column becomes nullable and loses its unique key, which the blind index
-- customers_by_email_index has taken over, so this release writes NULL into
-- it and `punch db:encrypt` clears what is left. Every row has its
-- ciphertext and blind index by now (`punch db:encrypt` in the release
-- before; db:audit shows none only in plaintext), so both become NOT NULL;
-- a row without them fails this migration, and the deploy stops.
-- rebuild: customers
CREATE TABLE customers_cleared (
  id              INTEGER PRIMARY KEY,
  organization_id INTEGER NOT NULL REFERENCES organizations (id),
  name            TEXT    NOT NULL COLLATE de,
  company_name    TEXT,
  email           TEXT,
  created_at      TEXT    NOT NULL,
  locale          TEXT,
  address         BLOB,
  tax_id          BLOB,
  tax_id_index    BLOB,
  email_encrypted BLOB    NOT NULL,
  email_index     BLOB    NOT NULL,
  UNIQUE (organization_id, id)
) STRICT;

INSERT INTO customers_cleared (id, organization_id, name, company_name, email, created_at, locale, address, tax_id, tax_id_index, email_encrypted, email_index)
  SELECT id, organization_id, name, company_name, email, created_at, locale, address, tax_id, tax_id_index, email_encrypted, email_index FROM customers;

DROP TABLE customers;
ALTER TABLE customers_cleared RENAME TO customers;

CREATE INDEX customers_by_name ON customers (organization_id, name);
CREATE UNIQUE INDEX customers_by_tax_id ON customers (organization_id, tax_id_index);
CREATE UNIQUE INDEX customers_by_email_index ON customers (organization_id, email_index);
