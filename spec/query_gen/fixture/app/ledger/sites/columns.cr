# Sites keep composites in groups of columns (docs/composites.md).

Punch.table "sites", Ledger::Sites,
  id: Ledger::Sites::ID,
  account_id: Ledger::Accounts::ID,
  address: {type: Ledger::Address, columns: "address_"},
  billing: {type: Ledger::Address?, columns: "billing_"},
  contact: {type: Ledger::Contact, columns: "contact_"},
  contact_phone_index: Punch::BlindIndex.of(:contact_phone)
