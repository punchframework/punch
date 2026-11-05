# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "receipts", Billing::Receipts,
  id: Billing::Receipts::ID,
  user_id: Accounts::Users::ID,
  description: Punch::NonEmptyString,
  scan: {type: Punch::Upload::File, columns: "file_"},
  created_at: Time
