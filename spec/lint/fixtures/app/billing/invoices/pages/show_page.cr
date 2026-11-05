# Punch/OperationFile: a page's own file, with the component only it
# renders; another page or an operation here is reported.
module Billing::Invoices
  struct DetailView
    include Punch::Component
  end

  struct ShowPage < Punch::Page
  end

  struct IndexPage < Punch::Page # expect
  end

  struct Show < Punch::Query # expect
  end
end
