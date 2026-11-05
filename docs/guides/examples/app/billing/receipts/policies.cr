module Billing::Receipts
  # A receipt is seen and deleted by the user who keeps it; to anyone else
  # it does not exist (404).
  struct Own
    include Punch::Policy

    def self.check(actor : Examples::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *,
                   receipt_id : ID) : Punch::Policy::Decision
      Table.find(db, receipt_id).try(&.user_id) == actor.user.id ? allow : not_found
    end
  end
end
