module Billing::Invoices
  # Links that show a sent invoice without signing in: the invoice ID,
  # signed with the app's key ring for this purpose only, valid for
  # `VALID`. Nothing is stored; a key rotation keeps old links working
  # until the old key is retired (lib/punch/docs/keys.md).
  module Sharing
    PURPOSE = "invoice_link"
    VALID   = 30.days

    def self.token(invoice : Invoice::Issued, expires_at : Time) : String
      Punch::KeyRing.current.signer(PURPOSE).sign_text(invoice.id.to_s, expires_at: expires_at)
    end

    # The invoice ID in *token*, or `nil` when it is forged, damaged, or
    # expired.
    def self.invoice_id(token : String, now : Time) : ID?
      Punch::KeyRing.current.signer(PURPOSE).verify_text(token, now).try { |raw| ID.parse(raw).as?(ID) }
    end
  end
end
