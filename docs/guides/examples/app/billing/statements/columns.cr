# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "statements", Billing::Statements,
  id: Billing::Statements::ID,
  user_id: Accounts::Users::ID,
  file: {type: Punch::Upload::PrivateFile, columns: "file_"},
  created_at: Time
