# Punch/OperationFile: outside app/ (the framework, specs) nothing is
# reported.
module Billing::Invoices
  struct Send < Punch::Command
  end
end
