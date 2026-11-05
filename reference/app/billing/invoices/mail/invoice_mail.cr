module Billing::Invoices
  # The mail that brings a sent invoice to its customer: the amount, the
  # due date, and a link that shows the invoice without signing in.
  struct InvoiceMail
    include Punch::Mail

    def initialize(@invoice : Invoice::Issued, @customer : Customers::Record, @link : Punch::Href, @issuer : String)
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(@customer.email_encrypted.unwrap, @customer.display_name)
    end

    def subject(locale : Punch::Locale) : String
      locale.t.invoices.mail.subject(number: @invoice.number.to_s, issuer: @issuer)
    end

    def view(v : Punch::View) : Nil
      t = v.t.invoices.mail
      number = @invoice.number.to_s
      v.p t.greeting(name: @customer.display_name)
      v.p t.body(number: number, total: v.locale.money(@invoice.total, @invoice.currency), due: v.locale.date(@invoice.due_at, :long))
      v.p { v.a t.open(number: number), href: @link }
      v.p t.validity
      v.p do
        v.text t.closing
        v.br
        v.text @issuer
      end
    end
  end
end
