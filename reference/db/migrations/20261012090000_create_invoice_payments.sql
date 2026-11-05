-- A sent invoice is paid once its payment arrives: the payment provider's
-- webhook (`Billing::Payments::Webhook`) records it here. A table of its
-- own instead of a new status: the previous release reads every invoice of
-- this schema as it did before, since `status` keeps its two values, and an
-- invoice has at most one payment.
CREATE TABLE invoice_payments (
  invoice_id INTEGER PRIMARY KEY REFERENCES invoices (id),
  -- The provider's ID of the payment.
  reference  TEXT    NOT NULL,
  amount     INTEGER NOT NULL,
  paid_at    TEXT    NOT NULL
) STRICT;
