-- Customers, the first fixture migration.
CREATE TABLE customers (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL
) STRICT;

CREATE INDEX customers_by_name ON customers (name);
