# Composites several entities of billing use (lib/punch/docs/composites.md).
# Read by `punch db:generate`, which writes them into composites.gen.cr.

# A postal address: where an organization does business.
Punch.composite Billing::Address,
  street: Punch::NonEmptyString,
  postal_code: Punch::NonEmptyString,
  city: Punch::NonEmptyString,
  country: Punch::NonEmptyString
