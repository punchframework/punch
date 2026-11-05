# Composites of the generator fixture (docs/composites.md), shared by
# sites (as groups of columns) and orders (inside JSON documents).

Punch.composite Ledger::Geo,
  lat: Float64,
  lng: Float64

Punch.composite Ledger::Address,
  street: Punch::NonEmptyString,
  city: Punch::NonEmptyString,
  country: {type: Punch::NonEmptyString, default: "DE"},
  geo: Ledger::Geo?

Punch.composite Ledger::Contact,
  name: Punch::NonEmptyString,
  phone: Punch::Encrypted(Punch::NonEmptyString)?

Punch.composite Ledger::Line,
  description: Punch::NonEmptyString,
  quantity: Float64,
  unit_price: Punch::Money,
  customer_id: Ledger::Customers::ID?

Punch.composite Ledger::Payment,
  discriminator: "kind",
  one_of: {card: Ledger::Card, transfer: Ledger::Transfer}

Punch.composite Ledger::Card,
  last4: Punch::NonEmptyString,
  brand: String

Punch.composite Ledger::Transfer,
  iban: Punch::NonEmptyString,
  reference: String?,
  booked_at: Time?
