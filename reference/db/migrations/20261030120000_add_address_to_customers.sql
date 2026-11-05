-- A customer's postal address, for invoices. Personal data, so it is
-- encrypted: app/billing/customers/columns.cr maps it as
-- Punch::Encrypted(Punch::NonEmptyString), and the column holds only
-- ciphertext (lib/punch/docs/queries.md#encrypted-columns).
ALTER TABLE customers ADD COLUMN address BLOB;
