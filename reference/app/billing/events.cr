# The billing slice's domain events (lib/punch/docs/events.md): what
# happened, with the IDs a subscriber needs to look up the rest.

module Billing
  # Included by every event that changes what a customer owes, so one
  # subscriber hears them all (`Customers::ForgetStatement`).
  module BalanceChanged
    abstract def customer_id : Customers::ID
  end

  # Included by every event that changes or deletes an existing invoice,
  # so a page that shows one invoice hears them all
  # (`Invoices::ShowPage#live`).
  module InvoiceChanged
    abstract def invoice_id : Invoices::ID
  end

  # A draft was started. Published by `Invoices::Create`.
  record InvoiceDrafted,
    invoice_id : Invoices::ID,
    organization_id : Accounts::Organizations::ID do
    include Punch::Event
  end

  # A draft's currency or lines changed. Published by `Invoices::Update`.
  record DraftRevised,
    invoice_id : Invoices::ID do
    include Punch::Event
    include InvoiceChanged
  end

  # A draft was deleted. Published by `Invoices::Destroy`; the
  # organization is in the event because nothing is left to look it up.
  record DraftDeleted,
    invoice_id : Invoices::ID,
    organization_id : Accounts::Organizations::ID do
    include Punch::Event
    include InvoiceChanged
  end

  # An invoice was issued to its customer: numbered, final, and due.
  # Published by `Invoices::Send` once the invoice is saved.
  record InvoiceSent,
    invoice_id : Invoices::ID,
    customer_id : Customers::ID do
    include Punch::Event
    include BalanceChanged
    include InvoiceChanged
  end

  # A sent invoice's payment arrived. Published by `Payments::Provider`.
  record InvoicePaid,
    invoice_id : Invoices::ID,
    customer_id : Customers::ID do
    include Punch::Event
    include BalanceChanged
    include InvoiceChanged
  end
end
