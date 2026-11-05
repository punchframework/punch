# Punch/OperationFile: operations outside the file named after them.
module Billing::Invoices
  struct Send < Punch::Command # expect
  end

  @[Punch::Public]
  struct Index < Query # expect
  end

  struct ShowPage < Punch::Page # expect
  end

  # Not operations: results, components, policies.
  struct Detail
  end

  struct DetailView
    include Punch::Component
  end
end

struct Billing::Customers::Create < Punch::Command # expect
end

# Jobs, mails, and subscribers too.
module Billing::Invoices
  struct Remind # expect
    include Punch::Job
  end

  struct InvoiceMail # expect
    include Punch::Mail
  end

  @[Punch::Subscriber::Delivery(:deferred)]
  struct MailInvoice # expect
    include Punch::Subscriber(InvoiceSent)
  end

  # Not shown by name: an event, a component.
  struct InvoiceSent
    include Punch::Event
  end
end
