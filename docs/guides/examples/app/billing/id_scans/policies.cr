module Billing::IdScans
  # An ID scan is seen by the user it belongs to; to anyone else it does
  # not exist (404).
  struct Own
    include Punch::Policy

    def self.check(actor : Examples::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *,
                   id_scan_id : ID) : Punch::Policy::Decision
      Table.find(db, id_scan_id).try(&.user_id) == actor.user.id ? allow : not_found
    end
  end
end
