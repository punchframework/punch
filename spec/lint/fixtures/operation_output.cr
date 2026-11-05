# Punch/OperationOutput applies only under app/.
module Billing::Invoices
  struct Send < Punch::Command
    def call(input : Input, db : Punch::Writer) : Detail
    end
  end
end
