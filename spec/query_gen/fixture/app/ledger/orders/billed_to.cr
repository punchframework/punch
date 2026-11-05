module Ledger::Orders
  # Who an order was billed to, as it was when billed.
  struct BilledTo
    # Version 1: the name only, as plain text.
    struct V1
      include Punch::Payloads::Frozen

      getter name : String

      def upgrade : BilledTo | Punch::Invalid
        case name = Punch::NonEmptyString.parse(@name)
        in Punch::Invalid        then name
        in Punch::NonEmptyString then BilledTo.build(name: name)
        end
      end
    end
  end
end
