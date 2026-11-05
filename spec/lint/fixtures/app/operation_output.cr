# Punch/OperationOutput: every operation declares `alias Output` and `call`
# returns it.
module Billing::Invoices
  struct Show < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader) : Output
    end
  end

  struct IndexPage < Punch::Page
    alias Output = Index::Output

    def call(input : Input, db : Punch::Reader) : Output
    end
  end

  struct Send < Punch::Command                                      # expect
    def call(input : Input, db : Punch::Writer) : Detail | NotFound # expect
    end
  end

  struct Update < Punch::Command
    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Writer) : Detail | NotFound # expect
    end
  end

  struct Destroy < Punch::Command               # expect
    def call(input : Input, db : Punch::Writer) # expect
    end
  end

  # Not an operation.
  struct Summary
    def call : Int32
    end
  end
end
