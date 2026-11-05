require "punch/spec"
require "../src/invoicing"

# What every spec file shares; the factories are per slice.
module InvoicingSpec
  def self.parse(type : T.class, raw) : T forall T
    type.parse(raw).as(T)
  end
end

require "./support/accounts"
require "./support/billing"

# A key for specs only; real keys come from `punch keys:rotate`.
Punch::Spec.credentials(Invoicing::Credentials, <<-YAML)
  secret_key_base: 1:2026-10-09:#{"5a" * 32}
  public_id_key: #{"6b" * 32}
  issuer:
    name: Example Consulting GmbH
    vat_id: DE123456789
  payments:
    webhook_secret: #{BillingSpec::WEBHOOK_SECRET}
  mail:
    delivery: capture
    from: invoices@example.org
    from_name: Example Consulting
  YAML
