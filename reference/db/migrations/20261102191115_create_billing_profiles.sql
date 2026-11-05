-- An organization's billing profile: its address, a group of columns
-- holding a Billing::Address (lib/punch/docs/composites.md).
CREATE TABLE billing_profiles (
  organization_id     INTEGER PRIMARY KEY REFERENCES organizations (id),
  address_street      TEXT    NOT NULL,
  address_postal_code TEXT    NOT NULL,
  address_city        TEXT    NOT NULL,
  address_country     TEXT    NOT NULL,
  updated_at          TEXT    NOT NULL
) STRICT;
