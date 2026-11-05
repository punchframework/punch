-- Invoices and their lines: a tier-2 model, one state type per status.
-- The CHECK keeps the columns each state needs together, so a row is
-- either a draft or a sent invoice and nothing in between.
CREATE TABLE invoices (
  id          INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers (id),
  currency    TEXT    NOT NULL,
  status      TEXT    NOT NULL,
  number      TEXT    UNIQUE,
  sent_at     TEXT,
  due_at      TEXT,
  created_at  TEXT    NOT NULL,
  CHECK (
    (status = 'draft' AND number IS NULL AND sent_at IS NULL AND due_at IS NULL) OR
    (status = 'sent' AND number IS NOT NULL AND sent_at IS NOT NULL AND due_at IS NOT NULL)
  )
) STRICT;

CREATE INDEX invoices_by_customer ON invoices (customer_id, id);

CREATE TABLE invoice_lines (
  id          INTEGER PRIMARY KEY,
  invoice_id  INTEGER NOT NULL REFERENCES invoices (id) ON DELETE CASCADE,
  position    INTEGER NOT NULL,
  description TEXT    NOT NULL,
  quantity    INTEGER NOT NULL CHECK (quantity > 0),
  unit_price  INTEGER NOT NULL,
  UNIQUE (invoice_id, position)
) STRICT;
