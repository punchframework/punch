# Orders keep JSON documents (docs/composites.md): a plain one with
# bounded lists, an encrypted one with versions, a polymorphic one.

Punch.composite Ledger::Orders::Shipment,
  address: Ledger::Address,
  lines: {type: Array(Ledger::Line), max: 50},
  prices: {type: Hash(Punch::Currency, Punch::Money), max: 5},
  express: {type: Bool, default: false},
  note: String?,
  payment: Ledger::Payment?

Punch.composite Ledger::Orders::BilledTo,
  version: 2, from: {1 => Ledger::Orders::BilledTo::V1},
  name: Punch::NonEmptyString,
  company: String?,
  contact: Ledger::Contact?

Punch.table "orders", Ledger::Orders,
  id: Ledger::Orders::ID,
  account_id: Ledger::Accounts::ID,
  shipping: Ledger::Orders::Shipment,
  billed_to: Punch::Encrypted(Ledger::Orders::BilledTo),
  payment: Ledger::Payment
