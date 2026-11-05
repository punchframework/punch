# Punch/OperationFile: the operation's own file; a second one is reported.
module Billing::Invoices
  @[Punch::Status(422)]
  struct NoLines
  end

  struct Send < Punch::Command
    struct Input
    end
  end

  struct Destroy < Punch::Command # expect
  end
end

module Billing
  struct Invoices::Send < Punch::Command
  end
end
