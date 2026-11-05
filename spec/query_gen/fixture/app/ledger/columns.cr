# Column to domain type mapping for the query generator fixture. Payments
# stay unmapped on purpose: their queries use stored types.

Punch.table "accounts", Ledger::Accounts,
  id: Ledger::Accounts::ID,
  created_at: Time

Punch.table "customers", Ledger::Customers,
  id: Ledger::Customers::ID,
  account_id: Ledger::Accounts::ID,
  email: Punch::Email,
  active: Bool,
  archived_at: Time

Punch.table "contacts", Ledger::Contacts,
  id: Ledger::Contacts::ID,
  customer_id: Ledger::Customers::ID,
  phone: Punch::Encrypted(Punch::NonEmptyString),
  note: Punch::Encrypted(String),
  born: Punch::Encrypted(Time),
  vip: Punch::Encrypted(Bool),
  phone_index: Punch::BlindIndex.of(:phone)

Punch.table "invoices", Ledger::Invoices,
  id: Ledger::Invoices::ID,
  account_id: Ledger::Accounts::ID,
  customer_id: Ledger::Customers::ID,
  number: Ledger::InvoiceNumber,
  sent_at: Time,
  created_at: Time

Punch.table "invoice_lines", Ledger::InvoiceLines,
  id: Ledger::InvoiceLines::ID,
  invoice_id: Ledger::Invoices::ID

Punch.table "settings", Ledger::Settings,
  account_id: Ledger::Accounts::ID

Punch.table "leads", Ledger::Leads,
  id: Ledger::Leads::ID,
  email_encrypted: Punch::Encrypted(Punch::Email).from(:email),
  email_index: Punch::BlindIndex.of(:email_encrypted)

Punch.table "prospects", Ledger::Prospects,
  id: Ledger::Prospects::ID,
  email_encrypted: Punch::Encrypted(Punch::Email).from(:email, clear: true)

Punch.violation "plan_locked", Ledger::Accounts::PlanLocked, status: 409
Punch.violation "name_blank", Ledger::Accounts::NameBlank, status: 422, field: "name"
