# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.
#
# Read as their stored types until mapped here:
#   invoices: Int64

Punch.table "paid_counts", Billing::PaidCounts,
  id: Billing::PaidCounts::ID,
  customer_email: Punch::Email
