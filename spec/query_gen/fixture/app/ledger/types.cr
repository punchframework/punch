# Domain types of the query generator fixture.
module Ledger
  struct Accounts::ID < Punch::TypedID
  end

  struct Customers::ID < Punch::TypedID
  end

  struct Invoices::ID < Punch::TypedID
  end

  struct Contacts::ID < Punch::TypedID
  end

  struct InvoiceLines::ID < Punch::TypedID
  end

  struct Leads::ID < Punch::TypedID
  end

  struct Prospects::ID < Punch::TypedID
  end

  struct Sites::ID < Punch::TypedID
  end

  struct Orders::ID < Punch::TypedID
  end

  # What an invoice's list filter calls its state; a paid invoice is a
  # sent one with a payment.
  enum InvoiceState
    Draft
    Sent
    Paid
  end

  struct InvoiceNumber
    include Punch::Primitive(String)

    def self.parse(raw : String) : self | Punch::Invalid
      return Punch::Invalid.new("invalid_invoice_number") unless raw.matches?(/\AINV-\d{4}\z/)

      new(raw)
    end
  end

  # Behaviour shared by the customer record and the rows of queries that
  # select a customer's email.
  module Emailed
    abstract def email : Punch::Email

    def email_domain : String
      email.value.partition('@').last
    end
  end
end
