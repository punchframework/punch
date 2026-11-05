-- Customers and invoices belong to the user who added them, and only that
-- user sees them. An invoice carries its customer's owner, so a user's
-- invoices are one index range; the composite foreign key keeps the two
-- owners equal. Email addresses are unique per owner: one user's customers
-- say nothing about another's.
--
-- Rows from before owners existed go to the first user. With customers
-- but no users, the migration fails on `owner_id NOT NULL`.
CREATE TABLE customers_new (
  id           INTEGER PRIMARY KEY,
  owner_id     INTEGER NOT NULL REFERENCES users (id),
  name         TEXT    NOT NULL COLLATE de,
  company_name TEXT,
  email        TEXT    NOT NULL,
  created_at   TEXT    NOT NULL,
  UNIQUE (owner_id, email),
  UNIQUE (owner_id, id)
) STRICT;

INSERT INTO customers_new (id, owner_id, name, company_name, email, created_at)
SELECT id, (SELECT min(id) FROM users), name, company_name, email, created_at FROM customers;

DROP TABLE customers;
ALTER TABLE customers_new RENAME TO customers;

CREATE INDEX customers_by_name ON customers (owner_id, name);

CREATE TABLE invoices_new (
  id          INTEGER PRIMARY KEY,
  owner_id    INTEGER NOT NULL,
  customer_id INTEGER NOT NULL,
  currency    TEXT    NOT NULL,
  status      TEXT    NOT NULL,
  number      TEXT    UNIQUE,
  sent_at     TEXT,
  due_at      TEXT,
  created_at  TEXT    NOT NULL,
  FOREIGN KEY (owner_id, customer_id) REFERENCES customers (owner_id, id),
  CHECK (
    (status = 'draft' AND number IS NULL AND sent_at IS NULL AND due_at IS NULL) OR
    (status = 'sent' AND number IS NOT NULL AND sent_at IS NOT NULL AND due_at IS NOT NULL)
  )
) STRICT;

INSERT INTO invoices_new (id, owner_id, customer_id, currency, status, number, sent_at, due_at, created_at)
SELECT invoices.id, customers.owner_id, invoices.customer_id, invoices.currency, invoices.status,
       invoices.number, invoices.sent_at, invoices.due_at, invoices.created_at
FROM invoices JOIN customers ON customers.id = invoices.customer_id;

DROP TABLE invoices;
ALTER TABLE invoices_new RENAME TO invoices;

CREATE INDEX invoices_by_owner ON invoices (owner_id, id);
CREATE INDEX invoices_by_customer ON invoices (customer_id, id);
