-- Converting customers.email to an encrypted column, first of three
-- releases (lib/punch/docs/queries.md#converting-a-plaintext-column): the
-- ciphertext goes in email_encrypted, with its blind index for the unique
-- key and lookups. app/billing/customers/columns.cr maps it with
-- from(:email), so this release reads either and writes both, and
-- `punch db:encrypt` (or the nightly job) converts the rows written before.
ALTER TABLE customers ADD COLUMN email_encrypted BLOB;
ALTER TABLE customers ADD COLUMN email_index BLOB;
CREATE UNIQUE INDEX customers_by_email_index ON customers (organization_id, email_index);
