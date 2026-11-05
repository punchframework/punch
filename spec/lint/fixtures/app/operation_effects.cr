# Fixture for Punch/OutsideCalls and Punch/NotNil.
module Billing::Invoices
  struct Send < Punch::Command
    def call(input : Input, db : Punch::Writer) : Output
      HTTP::Client.get("https://example.org")                 # calls
      socket = TCPSocket.new("example.org", 25)               # calls
      Process.run("lpr", ["invoice.pdf"])                     # calls
      Punch::Mailer.deliver(InvoiceMail.new)                  # calls
      response = ::HTTP::Client::Response.new(200)            # calls
      customer = Customers::Table.find(db, input.id).not_nil! # not_nil
      Punch::Mailer.preview(InvoiceMail.new)
    end
  end

  struct Sharing
    def self.expires : Time
      Time.utc + 1.day
    end

    def self.fetch : Nil
      HTTP::Client.get("https://example.org")
    end
  end
end
