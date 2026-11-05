# Fixture for Punch/SliceBoundary: the shop slice reaching into billing's
# and ledger's data, and what it may use.
module Shop
  struct Checkout
    def call(db : Punch::Writer, invoice_id : Billing::Invoices::ID)
      Billing::Invoices::Table.find(db, invoice_id)               # expect
      Billing::Invoices::Queries.for_customer(db, customer_id: 1) # expect
      Billing::Invoices::Store.load(db, invoice_id)               # expect
      ::Ledger::Entries::Queries::Page::Cursor                    # expect
      Ledger::PostingStore.save(db)                               # expect
      Billing::Invoices::Show.href(invoice_id: invoice_id)
      Billing::InvoiceSent.new(invoice_id: invoice_id)
      Shop::Orders::Table.find(db, 1)
      Orders::Store.load(db, 1)
      Accounts::Users::Table.find(db, 1)
    end
  end
end
