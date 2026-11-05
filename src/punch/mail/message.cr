module Punch::Mailer
  # A mail rendered for sending, as an adapter takes it. Made by
  # `Punch::Mailer.deliver`. *key* is the job's key, stable across
  # retries, for a provider that takes an idempotency key; *type* is the
  # mail's type, such as `Billing::Invoices::InvoiceMail`.
  record Message,
    subject : String,
    from : Mail::Address,
    to : Array(Mail::Address),
    reply_to : Mail::Address?,
    text : String,
    html : SafeHTML,
    key : String,
    type : String,
    locale : String
end
