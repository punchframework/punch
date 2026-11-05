# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

# Who a sent invoice bills, as the customer was when it was sent: kept with
# the invoice, encrypted as a whole, so a later edit of the customer
# changes no sent invoice (lib/punch/docs/composites.md).
Punch.composite Billing::Invoices::BilledTo,
  customer_id: Billing::Customers::ID,
  name: Punch::NonEmptyString,
  company_name: Punch::NonEmptyString?,
  address: Punch::NonEmptyString?,
  tax_id: Billing::Customers::TaxID?

Punch.table "invoices", Billing::Invoices,
  id: Billing::Invoices::ID,
  organization_id: Accounts::Organizations::ID,
  customer_id: Billing::Customers::ID,
  currency: Punch::Currency,
  number: Billing::Invoices::Number,
  sent_at: Time,
  due_at: Time,
  billed_to: Punch::Encrypted(Billing::Invoices::BilledTo),
  created_at: Time

Punch.table "invoice_lines", Billing::Invoices::Lines,
  id: Billing::Invoices::Lines::ID,
  invoice_id: Billing::Invoices::ID,
  description: Punch::NonEmptyString,
  quantity: Billing::Invoices::Quantity,
  unit_price: Punch::Money

Punch.table "invoice_payments", Billing::Invoices::Payments,
  invoice_id: Billing::Invoices::ID,
  reference: Punch::NonEmptyString,
  amount: Punch::Money,
  paid_at: Time

Punch.table "invoice_reminders", Billing::Invoices::Reminders,
  invoice_id: Billing::Invoices::ID,
  created_at: Time
