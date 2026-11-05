-- How many invoices each customer has paid, kept by an inline subscriber
-- in the transaction that records each payment, so it never disagrees
-- with the invoices.
CREATE TABLE paid_counts (
  id             INTEGER PRIMARY KEY,
  customer_email TEXT    NOT NULL UNIQUE,
  invoices       INTEGER NOT NULL
) STRICT;
