require "punch/spec"
require "../src/examples"

# What every spec file shares; the factories are per slice.
module ExamplesSpec
  def self.parse(type : T.class, raw) : T forall T
    type.parse(raw).as(T)
  end
end

require "./support/accounts"
require "./support/billing"

# A key for specs only; real keys come from `punch keys:rotate`.
Punch::Spec.credentials(Examples::Credentials, <<-YAML)
  secret_key_base: 1:2026-10-09:#{"5a" * 32}
  public_id_key: #{"6b" * 32}
  mail:
    delivery: capture
    from: examples@example.org
  alert_to: ops@example.org
  uploads:
    storage: local
  YAML
