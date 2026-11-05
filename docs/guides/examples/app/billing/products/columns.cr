# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

# What one unit of a product costs, per currency: at most three, kept
# with the product and never queried per currency.
Punch.composite Billing::Products::Pricing,
  unit: Punch::NonEmptyString,
  prices: {type: Hash(Punch::Currency, Punch::Money), max: 3}

Punch.table "products", Billing::Products,
  id: Billing::Products::ID,
  name: Punch::NonEmptyString,
  pricing: Billing::Products::Pricing
