-- The generator's broad fixture.
-- Each numbered comment introduces the query below it.

-- 1. Primary-key lookup, whole row
-- name: InvoiceById :one
-- The whole row, so it returns the invoices record.
SELECT * FROM invoices WHERE id = :id;

-- 2. Narrow select with ordering and paging
-- name: InvoicesForCustomer :many
SELECT id, number, total_cents, sent_at
FROM invoices
WHERE customer_id = :customer_id
ORDER BY created_at DESC
LIMIT :limit OFFSET :offset;

-- 3. Lookup by unique key
-- name: CustomerByEmail :one
SELECT id, name, company_name FROM customers
WHERE account_id = :account_id AND email = :email;

-- 4. Comparison operators on dates
-- name: OverdueInvoices :many
SELECT id, number, due_on FROM invoices
WHERE account_id = :account_id AND status = 'sent' AND due_on < :today;

-- 5. LIKE with a parameter inside an expression
-- name: CustomersMatching :many
SELECT id, name FROM customers
WHERE account_id = :account_id AND name LIKE '%' || :q || '%' ESCAPE '\'
ORDER BY name;

-- 6. Inner join
-- name: InvoicesWithCustomer :many
-- include Ledger::Emailed
SELECT i.id, i.number, i.total_cents, c.name AS customer_name, c.email
FROM invoices i
JOIN customers c ON c.id = i.customer_id
WHERE i.account_id = :account_id;

-- 7. Three-way join
-- name: LinesForAccount :many
SELECT l.id, l.description, l.quantity, i.number, c.name AS customer_name
FROM invoice_lines l
JOIN invoices i ON i.id = l.invoice_id
JOIN customers c ON c.id = i.customer_id
WHERE i.account_id = :account_id;

-- 8. Self-describing join with table-qualified star
-- name: InvoiceWithAccount :one
SELECT i.*, a.name AS account_name
FROM invoices i JOIN accounts a ON a.id = i.account_id
WHERE i.id = :id;

-- 9. Left join: right-hand columns may be NULL
-- name: InvoicesWithLastPayment :many
SELECT i.id, i.number, p.amount_cents, p.paid_at
FROM invoices i
LEFT JOIN payments p ON p.invoice_id = i.id
WHERE i.account_id = :account_id;

-- 10. Left join with aggregate
-- name: CustomersWithInvoiceCount :many
SELECT c.id, c.name, count(i.id) AS invoice_count
FROM customers c
LEFT JOIN invoices i ON i.customer_id = c.id
WHERE c.account_id = :account_id
GROUP BY c.id;

-- 11. count(*)
-- name: CountInvoices :one
SELECT count(*) AS n FROM invoices WHERE account_id = :account_id;

-- 12. sum() can be NULL on no rows
-- name: OpenAmount :one
SELECT sum(total_cents) AS open_cents FROM invoices
WHERE account_id = :account_id AND status = 'sent';

-- 13. total() is never NULL, and is REAL
-- name: PaidTotal :one
SELECT total(amount_cents) AS paid FROM payments WHERE invoice_id = :invoice_id;

-- 14. Group by with HAVING
-- name: RevenueByStatus :many
SELECT status, count(*) AS invoices, sum(total_cents) AS cents
FROM invoices WHERE account_id = :account_id
GROUP BY status HAVING count(*) > :min_count;

-- 15. min/max
-- name: InvoiceDateRange :one
SELECT min(issued_on) AS first_issued, max(issued_on) AS last_issued
FROM invoices WHERE account_id = :account_id;

-- 16. Arithmetic on columns
-- name: LineTotals :many
SELECT id, description, quantity * unit_price_cents AS line_cents
FROM invoice_lines WHERE invoice_id = :invoice_id ORDER BY position;

-- 17. COALESCE with a literal fallback
-- name: CustomerDisplayNames :many
SELECT id, coalesce(company_name, name) AS display_name, coalesce(vat_id, '') AS vat
FROM customers WHERE account_id = :account_id;

-- 18. CASE expression
-- name: InvoiceBadges :many
SELECT id, CASE WHEN sent_at IS NULL THEN 'draft' ELSE 'sent' END AS badge
FROM invoices WHERE account_id = :account_id;

-- 19. Date function
-- name: InvoicesIssuedSince :many
SELECT id, number, date(issued_on) AS issued
FROM invoices WHERE issued_on >= date(:since) AND account_id = :account_id;

-- 20. EXISTS subquery
-- name: CustomersWithUnpaid :many
SELECT c.id, c.name FROM customers c
WHERE c.account_id = :account_id
  AND EXISTS (SELECT 1 FROM invoices i WHERE i.customer_id = c.id AND i.status = 'sent');

-- 21. Scalar subquery in the select list
-- name: InvoiceWithPaid :one
SELECT i.id, i.total_cents,
       (SELECT sum(p.amount_cents) FROM payments p WHERE p.invoice_id = i.id) AS paid_cents
FROM invoices i WHERE i.id = :id;

-- 22. Common table expression
-- name: TopCustomers :many
-- column cents: Int64
WITH totals AS (
  SELECT customer_id, sum(total_cents) AS cents FROM invoices
  WHERE account_id = :account_id GROUP BY customer_id
)
SELECT c.id, c.name, t.cents FROM totals t JOIN customers c ON c.id = t.customer_id
ORDER BY t.cents DESC LIMIT :limit;

-- 23. Window function
-- name: RunningTotals :many
SELECT id, issued_on, total_cents,
       sum(total_cents) OVER (ORDER BY issued_on, id) AS running_cents
FROM invoices WHERE customer_id = :customer_id;

-- 24. Insert returning the whole row
-- name: InsertInvoice :one
INSERT INTO invoices (account_id, customer_id, number, created_at)
VALUES (:account_id, :customer_id, :number, :created_at)
RETURNING *;

-- 25. Insert with optional columns, returning some
-- name: InsertCustomer :one
INSERT INTO customers (account_id, name, email, company_name)
VALUES (:account_id, :name, :email, :company_name)
RETURNING id, email;

-- 26. Update with a guard, returning
-- name: MarkSent :one
UPDATE invoices SET sent_at = :now, status = 'sent'
WHERE id = :id AND sent_at IS NULL
RETURNING id, sent_at;

-- 27. Update with arithmetic on a parameter
-- name: AddToTotal :execrows
UPDATE invoices SET total_cents = total_cents + :delta_cents WHERE id = :id;

-- 28. Delete
-- name: DeleteLine :exec
DELETE FROM invoice_lines WHERE id = :id AND invoice_id = :invoice_id;

-- 29. Upsert
-- name: UpsertAccountPlan :one
INSERT INTO accounts (id, name, plan, created_at) VALUES (:id, :name, :plan, :created_at)
ON CONFLICT (id) DO UPDATE SET plan = excluded.plan
RETURNING id, plan;

-- 30. IN list through json_each
-- name: InvoicesByIds :many
-- param ids: String
SELECT id, number FROM invoices WHERE id IN (SELECT value FROM json_each(:ids));

-- 31. JSON aggregation
-- name: InvoiceLinesJson :one
SELECT i.id, json_group_array(json_object('d', l.description, 'q', l.quantity)) AS lines_json
FROM invoices i JOIN invoice_lines l ON l.invoice_id = i.id
WHERE i.id = :id GROUP BY i.id;

-- 32. Declared clauses: filters and orders
-- name: Search :many
SELECT i.id, i.number, i.total_cents, i.status, c.name AS customer_name
FROM invoices i
JOIN customers c ON c.id = i.customer_id
WHERE i.account_id = :account_id
-- when status:       AND i.status = :status
-- when customer_id:  AND i.customer_id = :customer_id
-- when issued_from:  AND i.issued_on >= :issued_from
-- when q:            AND c.name LIKE '%' || :q || '%' ESCAPE '\'
-- order issued:      ORDER BY i.issued_on, i.id
-- order amount:      ORDER BY i.total_cents, i.id
LIMIT :limit OFFSET :offset;

-- 33. Characters Crystal would read as an escape or interpolation
-- name: Literals :one
SELECT '\n' || '#{total}' AS text;

-- 34. A clause without a parameter, and clauses on the statement's last lines
-- name: CountFiltered :one
SELECT count(*) AS invoices FROM invoices
WHERE account_id = :account_id
-- when unsent: AND sent_at IS NULL
-- when customer_id: AND customer_id = :customer_id

-- 35. Keyset pagination: a cursor per order and direction, one
-- order mixed
-- name: InvoicePage :page
SELECT i.id, i.number, i.total_cents, i.created_at, c.name AS customer_name
FROM invoices i
JOIN customers c ON c.id = i.customer_id
WHERE i.account_id = :account_id
-- when status: AND i.status = :status
-- order created: ORDER BY i.created_at, i.id
-- order amount: ORDER BY i.total_cents, i.id DESC
-- order customer: ORDER BY customer_name, i.id

-- 36. A page in the statement's own order, which ends on the WHERE's line
-- name: CustomerPage :page
SELECT * FROM customers WHERE account_id = :account_id ORDER BY name, id;

-- 37. An enum filter field: one clause per member, the enum named in the
-- header; paid is a payment, not a status
-- name: InvoicesInState :many
-- param state: Ledger::InvoiceState
SELECT i.id, i.number FROM invoices i
WHERE i.account_id = :account_id
-- when state = draft: AND i.status = 'draft'
-- when state = sent:  AND i.status = 'sent' AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id = i.id)
-- when state = paid:  AND EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id = i.id)
-- when customer_id:   AND i.customer_id = :customer_id
ORDER BY i.id;

-- 38. Encrypted columns: parameters written to them are
-- encrypted, selected ones decrypted; an expression over one is ciphertext
-- name: ContactPhones :many
SELECT id, phone, note, coalesce(note, phone) AS either FROM contacts WHERE customer_id = :customer_id ORDER BY id;

-- name: SetContactNote :exec
UPDATE contacts SET note = :note WHERE id = :id;

-- name: ContactByPhone :one
SELECT * FROM contacts WHERE customer_id = :customer_id AND phone_index = :phone;

-- name: ContactIds :many
SELECT id FROM contacts WHERE customer_id = :customer_id
-- when phone: AND phone_index = :phone
ORDER BY id;

-- name: SetContactPhone :exec
UPDATE contacts SET phone = :phone, phone_index = :phone_index WHERE id = :id;

-- name: LeadByEmail :one
SELECT * FROM leads WHERE email_index = :email;

-- name: OldLeadByEmail :one
SELECT id FROM leads WHERE email = :email;

-- name: ProspectNames :many
SELECT id, name, email_encrypted FROM prospects ORDER BY id;

-- 39. Array parameters through carray: typed by the compared column, and
-- for a blind index the elements' hashes under every key
-- name: InvoicesIn :many
SELECT id, number FROM invoices WHERE id IN carray(:ids) ORDER BY id;

-- name: ContactsByPhones :many
SELECT id FROM contacts WHERE phone_index IN carray(:phones) ORDER BY id;

-- 32. Composites: a query that selects every column of a group gets it as one field
-- name: SitesInCity :many
SELECT id, address_street, address_city, address_country, address_geo_lat, address_geo_lng
FROM sites
WHERE account_id = :account_id AND address_city = :city
ORDER BY id;

-- 33. Some columns of a group stay separate fields, each of its field's type
-- name: SiteCities :many
SELECT id, address_city FROM sites WHERE account_id = :account_id;

-- 34. The whole row: the record, with its groups
-- name: SiteById :one
SELECT * FROM sites WHERE id = :id;

-- 35. Typed paths into a document
-- name: OrdersIn :many
SELECT id,
  shipping ->> '$.address.city' AS city,
  json_extract(shipping, '$.lines[0].quantity') AS first_quantity,
  shipping ->> '$.payment.kind' AS payment_kind,
  shipping ->> 'express' AS express,
  shipping ->> '$.address' AS address,
  shipping ->> '$.prices.EUR' AS euros,
  ship_city
FROM orders
WHERE account_id = :account_id AND ship_city = :city;

-- 36. A parameter compared with a path takes the path's type
-- name: OrdersToCountry :many
SELECT id FROM orders WHERE account_id = :account_id AND shipping ->> '$.address.country' = :country;

-- 37. A document written whole through a parameter
-- name: SetPayment :exec
UPDATE orders SET payment = :payment WHERE id = :id;
