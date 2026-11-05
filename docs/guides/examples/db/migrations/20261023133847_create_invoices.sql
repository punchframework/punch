-- Invoices, as much of them as the guides' job examples need: who pays,
-- when the invoice is due, whether it is paid, and when its customer was
-- last reminded.
CREATE TABLE invoices (
  id             INTEGER PRIMARY KEY,
  number         TEXT    NOT NULL UNIQUE,
  customer_email TEXT    NOT NULL,
  due_at         TEXT    NOT NULL,
  paid_at        TEXT,
  reminded_at    TEXT
) STRICT;

-- The unpaid ones by due date, for the overdue sweep.
CREATE INDEX invoices_unpaid ON invoices (due_at) WHERE paid_at IS NULL;
