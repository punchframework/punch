-- Customers: reference data, a tier-1 model (behaviour on the generated record).
CREATE TABLE customers (
  id           INTEGER PRIMARY KEY,
  name         TEXT    NOT NULL,
  company_name TEXT,
  email        TEXT    NOT NULL UNIQUE,
  created_at   TEXT    NOT NULL
) STRICT;
