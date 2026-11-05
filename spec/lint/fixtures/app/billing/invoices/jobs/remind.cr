# Punch/OperationFile: a job in its own file under jobs/.
module Billing::Invoices
  struct Remind
    include Punch::Job
  end

  struct Escalate # expect
    include Punch::Job
  end
end
