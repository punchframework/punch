-- A customer's VAT or tax number. For a sole trader it is personal data, so
-- it is encrypted, and found through a blind index: tax_id_index holds a
-- keyed hash of the number (app/billing/customers/columns.cr,
-- lib/punch/docs/queries.md#blind-indexes). The unique index keeps each
-- organization's numbers unique and serves the list's tax_id filter.
ALTER TABLE customers ADD COLUMN tax_id BLOB;
ALTER TABLE customers ADD COLUMN tax_id_index BLOB;
CREATE UNIQUE INDEX customers_by_tax_id ON customers (organization_id, tax_id_index);
