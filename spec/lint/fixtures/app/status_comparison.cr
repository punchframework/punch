# Punch/StatusComparison: status checks inside operations.
module Billing::Invoices
  class Send < Punch::Command
    def call(input : Input, db : Punch::Writer) : Nil
      invoice = Store.load(db, input.invoice_id)
      return if invoice.status == Invoice::Status::Sent # expect
      return if "sent" != row.status                    # expect
      return if invoice.status.sent?                    # expect
      return if invoice.status.in?(:sent, :paid)        # expect
      case row.status                                   # expect
      when "draft" then nil
      end
      invoice.status.nil?
      status == "x"
      Detail.new(status: invoice.status)
      case invoice
      in Invoice::Sent then nil
      end
    end
  end

  class Index < Query
    def call(input : Input, db : Punch::Reader) : Nil
      rows.select(&.status.==("sent"))            # expect
      rows.reject { |row| row.status == "draft" } # expect
    end
  end

  # Not an operation: a store or a result may look at statuses.
  module Store
    def self.status(row) : Nil
      row.status == "draft"
    end
  end
end
