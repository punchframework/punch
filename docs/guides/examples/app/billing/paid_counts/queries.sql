-- Named queries of Billing::PaidCounts (lib/punch/docs/queries.md): each starts with
-- `-- name: Name :one|:many|:page|:exec|:execrows`, and `punch
-- db:generate` turns it into a typed method. Billing::PaidCounts::Table already
-- finds, inserts, updates, and deletes one row.

-- name: Count :exec
-- One more paid invoice for *customer_email*.
INSERT INTO paid_counts (customer_email, invoices) VALUES (:customer_email, 1)
ON CONFLICT (customer_email) DO UPDATE SET invoices = invoices + 1;
