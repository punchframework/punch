-- Customer names sort as German readers expect (Ärger before zulu). SQLite
-- cannot change a column's collation in place, so the table is rebuilt;
-- foreign keys are off during migrations, and invoices keep referring to
-- customers by name.
CREATE TABLE customers_new (
  id           INTEGER PRIMARY KEY,
  name         TEXT    NOT NULL COLLATE de,
  company_name TEXT,
  email        TEXT    NOT NULL UNIQUE,
  created_at   TEXT    NOT NULL
) STRICT;

INSERT INTO customers_new (id, name, company_name, email, created_at)
SELECT id, name, company_name, email, created_at FROM customers;

DROP TABLE customers;
ALTER TABLE customers_new RENAME TO customers;

CREATE INDEX customers_by_name ON customers (name);
