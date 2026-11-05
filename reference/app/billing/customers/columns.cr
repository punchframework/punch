# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

Punch.table "customers", Billing::Customers,
  id: Billing::Customers::ID,
  organization_id: Accounts::Organizations::ID,
  name: Punch::NonEmptyString,
  company_name: Punch::NonEmptyString,
  address: Punch::Encrypted(Punch::NonEmptyString),
  tax_id: Punch::Encrypted(Billing::Customers::TaxID),
  tax_id_index: Punch::BlindIndex.of(:tax_id),
  email_encrypted: Punch::Encrypted(Punch::Email),
  email_index: Punch::BlindIndex.of(:email_encrypted),
  created_at: Time,
  locale: Punch::LocaleTag
