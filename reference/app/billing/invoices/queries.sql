-- name: Organization :one
-- Which organization an invoice belongs to, for the policy.
SELECT organization_id FROM invoices WHERE id = :invoice_id;

-- name: Sender :one
-- The address an invoice is sent from: its organization's billing
-- profile, if it has one. All of the group's columns, so it reads as one
-- Billing::Address.
SELECT billing_profiles.address_street, billing_profiles.address_postal_code,
  billing_profiles.address_city, billing_profiles.address_country
FROM invoices JOIN billing_profiles ON billing_profiles.organization_id = invoices.organization_id
WHERE invoices.id = :invoice_id;

-- name: Page :page
-- One organization's invoices with their customer's name and total, a
-- page at a time in the order they were created; of one customer, in one
-- state, or matching a search, when the filter says so. A paid invoice is
-- a sent one with a payment. The customer comes from the query string,
-- which no policy sees, so the organization scopes the list in either
-- case. The search finds an invoice number by its start and a customer
-- by any part of the name, in any case. `page_by_key` is the one invoice
-- of it, for an open list (`IndexPage#live`) to decide what a change means.
-- include Billing::Invoices::Invoice::Due
-- param status: Billing::Invoices::Invoice::Status
SELECT
  invoices.id, invoices.status, invoices.number, invoices.currency,
  invoices.customer_id, customers.name AS customer_name,
  coalesce(sum(invoice_lines.quantity * invoice_lines.unit_price), 0) AS total,
  invoices.sent_at, invoices.due_at, invoice_payments.paid_at
FROM invoices
JOIN customers ON customers.id = invoices.customer_id
LEFT JOIN invoice_lines ON invoice_lines.invoice_id = invoices.id
LEFT JOIN invoice_payments ON invoice_payments.invoice_id = invoices.id
WHERE invoices.organization_id = :organization_id
-- when customer_id: AND invoices.customer_id = :customer_id
-- when q: AND (invoices.number LIKE :q || '%' ESCAPE '\' OR customers.name LIKE '%' || :q || '%' ESCAPE '\')
-- when status = draft: AND invoices.status = 'draft'
-- when status = sent:  AND invoices.status = 'sent' AND invoice_payments.invoice_id IS NULL
-- when status = paid:  AND invoice_payments.invoice_id IS NOT NULL
GROUP BY invoices.id
ORDER BY invoices.id;

-- name: Lines :many
-- The lines of one invoice, in order.
SELECT * FROM invoice_lines WHERE invoice_id = :invoice_id ORDER BY position;

-- name: Save :execrows
-- Writes an invoice's state. Its organization and customer never change.
UPDATE invoices
SET currency = :currency, status = :status, number = :number, sent_at = :sent_at, due_at = :due_at, billed_to = :billed_to
WHERE id = :id;

-- name: DeleteLines :exec
DELETE FROM invoice_lines WHERE invoice_id = :invoice_id;

-- name: LastSequence :one
-- The numeric part of the last invoice number issued, 0 before the first.
SELECT coalesce(max(CAST(substr(number, 5) AS INTEGER)), 0) AS sequence
FROM invoices
WHERE number IS NOT NULL;

-- name: AddReminder :execrows
-- Records that a sent invoice came due, once per invoice: a reminder job
-- that runs twice writes one row.
INSERT INTO invoice_reminders (invoice_id, created_at) VALUES (:invoice_id, :created_at)
ON CONFLICT (invoice_id) DO NOTHING;

-- name: Reminded :one
-- When an invoice's reminder was recorded.
SELECT created_at FROM invoice_reminders WHERE invoice_id = :invoice_id;

-- name: Payment :one
-- The payment of one invoice, if it was paid.
SELECT * FROM invoice_payments WHERE invoice_id = :invoice_id;

-- name: RecordPayment :exec
-- Records a sent invoice's payment. An invoice is paid once: the store
-- writes this only for an invoice it loaded as unpaid in the same
-- transaction.
INSERT INTO invoice_payments (invoice_id, reference, amount, paid_at)
VALUES (:invoice_id, :reference, :amount, :paid_at);

-- name: IdByNumber :one
-- The invoice that carries a number, for a payment that names it.
SELECT id FROM invoices WHERE number = :number;

-- name: OverdueWithoutReminder :many
-- Sent, unpaid invoices of every organization past their due date with no
-- reminder yet, after :after in ID order, :limit at a time: what
-- `RemindOverdue` walks.
-- scan: a daily sweep walks every sent invoice once, through invoices_sent_by_id; batches after the first start at :after
SELECT invoices.id
FROM invoices
LEFT JOIN invoice_reminders ON invoice_reminders.invoice_id = invoices.id
LEFT JOIN invoice_payments ON invoice_payments.invoice_id = invoices.id
WHERE invoices.status = 'sent' AND invoices.due_at < :now
  AND invoice_reminders.invoice_id IS NULL AND invoice_payments.invoice_id IS NULL
-- when after: AND invoices.id > :after
ORDER BY invoices.id
LIMIT :limit;
