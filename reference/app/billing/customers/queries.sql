-- name: Organization :one
-- Which organization a customer belongs to, for the policy.
SELECT organization_id FROM customers WHERE id = :customer_id;

-- name: Page :page
-- One organization's customers, a page at a time: in the order they were
-- created, or by name in the column's collation (through
-- customers_by_name); or the one with a tax number, through its blind
-- index (customers_by_tax_id).
SELECT * FROM customers
WHERE organization_id = :organization_id
-- when tax_id: AND tax_id_index = :tax_id
-- order created: ORDER BY id
-- order name: ORDER BY name, id

-- name: Search :many
-- One organization's customers whose name starts with the prefix, in any
-- case and script, sorted by name in the column's collation.
SELECT * FROM customers
WHERE organization_id = :organization_id AND name LIKE :prefix || '%' ESCAPE '\'
ORDER BY name, id
LIMIT :limit;

-- name: Statement :many
-- One customer's sent invoices per currency: how many, how many unpaid
-- ones were overdue at :now, what they total, and how much of it is not
-- paid yet. Each invoice's lines are summed through its own index range.
-- sort: one customer's sent invoices, grouped by currency
SELECT
  sent.currency,
  count(*) AS invoices,
  coalesce(sum(sent.unpaid AND sent.late), 0) AS overdue,
  coalesce(sum(sent.total), 0) AS total,
  coalesce(sum(CASE WHEN sent.unpaid THEN sent.total ELSE 0 END), 0) AS outstanding
FROM (
  SELECT invoices.currency, invoices.due_at < :now AS late, invoice_payments.invoice_id IS NULL AS unpaid,
         (SELECT sum(quantity * unit_price) FROM invoice_lines WHERE invoice_lines.invoice_id = invoices.id) AS total
  FROM invoices
  LEFT JOIN invoice_payments ON invoice_payments.invoice_id = invoices.id
  WHERE invoices.customer_id = :customer_id AND invoices.status = 'sent'
) AS sent
GROUP BY sent.currency
ORDER BY sent.currency;
