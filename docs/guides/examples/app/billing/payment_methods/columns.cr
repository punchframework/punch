# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).
# Read by `punch db:generate` and required by the app.

# A card or a transfer, told apart by `kind` in the stored document.
Punch.composite Billing::PaymentMethods::Method,
  discriminator: "kind",
  one_of: {card: Billing::PaymentMethods::Card, transfer: Billing::PaymentMethods::Transfer}

# A card, by its brand and the last four digits of its number; the rest
# stays with the payment provider.
Punch.composite Billing::PaymentMethods::Card,
  brand: Punch::NonEmptyString,
  last4: Punch::NonEmptyString

# A bank transfer from an account, with the reference the customer puts
# on it, if any.
Punch.composite Billing::PaymentMethods::Transfer,
  iban: Punch::NonEmptyString,
  reference: Punch::NonEmptyString?

Punch.table "payment_methods", Billing::PaymentMethods,
  id: Billing::PaymentMethods::ID,
  customer_email: Punch::Email,
  method: Billing::PaymentMethods::Method
