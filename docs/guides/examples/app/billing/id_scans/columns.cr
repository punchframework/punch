# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "id_scans", Billing::IdScans,
  id: Billing::IdScans::ID,
  user_id: Accounts::Users::ID,
  photo: {type: Punch::Upload::PrivateImageFile, columns: "photo_"}
