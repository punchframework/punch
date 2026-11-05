-- Who a sent invoice bills, as the customer was when it was sent: a
-- Billing::Invoices::BilledTo document, encrypted as a whole (ciphertext,
-- so no CHECK). Invoices sent before have none.
ALTER TABLE invoices ADD COLUMN billed_to BLOB;
