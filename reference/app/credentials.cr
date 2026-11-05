# What the app needs from its deployment, checked at boot (lib/punch/docs/credentials.md): each
# value from the environment first (ISSUER__NAME), then from the encrypted
# config/credentials/<env>.yml.enc. `bin/invoicing creds:check` shows where
# each came from.
struct Invoicing::Credentials
  include Punch::Credentials

  # Signs invoice links (`Invoices::Sharing`); rotated with `punch keys:rotate`.
  getter secret_key_base : Punch::KeyRing
  # The key of invoices' and customers' public IDs (`public_id` in their
  # types.cr); never rotated, since every link that holds one depends on it
  # (lib/punch/docs/keys.md).
  getter public_id_key : Punch::PublicIDKey
  getter issuer : Issuer
  # The payment provider's webhooks (`Billing::Payments::Provider`).
  getter payments : Payments
  # How mail leaves the app (`Billing::Invoices::MailInvoice`): captured
  # in development (MAIL__DELIVERY=capture), sent by SMTP in production.
  getter mail : Punch::Mailer::Settings

  # Who issues the invoices; shown on each one.
  struct Issuer
    include Punch::Credentials

    getter name : Punch::NonEmptyString
    getter vat_id : Punch::NonEmptyString?
  end

  struct Payments
    include Punch::Credentials

    # The provider's signing secret (`whsec_…`), and the one before it
    # while the provider rotates them. Without one the app takes no
    # payments.
    getter webhook_secret : Punch::Secret(String)?
    getter previous_webhook_secret : Punch::Secret(String)?

    # Every secret a delivery may be signed with; `nil` without any.
    def webhook_secrets : Array(String)?
      secret = webhook_secret || return
      [secret.unwrap, previous_webhook_secret.try(&.unwrap)].compact
    end
  end
end
