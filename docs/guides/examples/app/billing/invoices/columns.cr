# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.
#
# Read as their stored types until mapped here:
#   number: String

Punch.table "invoices", Billing::Invoices,
  id: Billing::Invoices::ID,
  customer_email: Punch::Email,
  due_at: Time,
  paid_at: Time,
  reminded_at: Time
