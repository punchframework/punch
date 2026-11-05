-- name: Overdue :many
-- Unpaid invoices due before :now whose customer was not reminded since
-- :since, oldest first, at most 500 per sweep: the next sweep takes the
-- rest.
SELECT id, reminded_at FROM invoices
WHERE paid_at IS NULL AND due_at < :now AND (reminded_at IS NULL OR reminded_at < :since)
ORDER BY due_at, id
LIMIT 500;

-- name: MarkReminded :exec
UPDATE invoices SET reminded_at = :now WHERE id = :id;

-- name: MarkPaid :exec
UPDATE invoices SET paid_at = :now WHERE id = :id;

-- name: DueBetween :many
-- Unpaid invoices due from :from and before :before, by due date, at
-- most 500.
SELECT id, number, customer_email, due_at, paid_at FROM invoices
WHERE paid_at IS NULL AND due_at >= :from AND due_at < :before
ORDER BY due_at, id
LIMIT 500;
