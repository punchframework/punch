# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "logos", Billing::Logos,
  id: Billing::Logos::ID,
  user_id: Accounts::Users::ID,
  image: {type: Punch::Upload::ImageFile, columns: "image_"}
