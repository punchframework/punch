module Punch
  # A mail: a component with recipients and a subject. One `view` yields
  # both parts, HTML from the HTML backend and plain text from the text
  # backend, in the recipient's locale; links become absolute URLs below
  # `Punch.public_url`.
  #
  # ```
  # struct Billing::Invoices::InvoiceMail
  #   include Punch::Mail
  #
  #   def initialize(@invoice : Invoice::Issued, @customer : Customers::Record, @link : Punch::Href)
  #   end
  #
  #   def to : Punch::Mail::Address
  #     Punch::Mail::Address.new(@customer.email, @customer.display_name)
  #   end
  #
  #   def subject(locale : Punch::Locale) : String
  #     locale.t.mail.invoice.subject(number: @invoice.number.to_s)
  #   end
  #
  #   def view(v : Punch::View) : Nil
  #     v.p v.t.mail.invoice.greeting(name: @customer.display_name)
  #     v.p { v.a v.t.mail.invoice.open, href: @link }
  #   end
  # end
  # ```
  #
  # The view takes a plain `Punch::View`: no `raw`, no forms, no document
  # (Punch writes it, with the subject as its title). Send a mail from a
  # job with `Punch::Mailer.deliver`.
  module Mail
    include Component

    # The recipients.
    abstract def to : Mail::Address | Array(Mail::Address)

    # The subject in *locale*, the recipient's.
    abstract def subject(locale : Locale) : String

    abstract def view(v : View) : Nil

    # Where replies go; the sender (`Punch::Mailer::Settings#from`) unless
    # given.
    def reply_to : Mail::Address?
      nil
    end
  end
end
