-- Named queries of Billing::PaymentMethods (lib/punch/docs/queries.md): each starts with
-- `-- name: Name :one|:many|:page|:exec|:execrows`, and `punch
-- db:generate` turns it into a typed method. Billing::PaymentMethods::Table already
-- finds, inserts, updates, and deletes one row.

-- name: OfCustomer :many
-- A customer's payment methods, oldest first.
SELECT id, method FROM payment_methods WHERE customer_email = :customer_email ORDER BY id;

-- name: CardBrands :many
-- The brands of a customer's cards: a path into the document, typed from
-- the composite. `brand` is nilable, since only cards have one.
SELECT id, method ->> '$.brand' AS brand
FROM payment_methods
WHERE customer_email = :customer_email AND method ->> '$.kind' = 'card'
ORDER BY id;
