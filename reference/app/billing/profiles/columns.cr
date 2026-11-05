# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "billing_profiles", Billing::Profiles,
  organization_id: Accounts::Organizations::ID,
  address: {type: Billing::Address, columns: "address_"},
  updated_at: Time
