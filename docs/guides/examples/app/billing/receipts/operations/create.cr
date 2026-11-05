module Billing::Receipts
  @[Punch::Status(201)]
  record Created,
    receipt : Detail do
    include JSON::Serializable
  end

  # Saves a receipt with the scan its ticket names. The claim is part of
  # this transaction: a refusal after it leaves the ticket claimable.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter description : Punch::NonEmptyString
      getter scan : Punch::Upload::Ticket
    end

    alias Output = Created | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      case file = Punch::Upload.claim(db, input.scan, Scan, owner: actor.user.id.to_s)
      in Punch::Invalid then Punch::Rejection.new(Punch::Rejection::Path{"scan"}, file)
      in Punch::Upload::File
        receipt = Punch.cannot_violate(Table.insert(db, user_id: actor.user.id, description: input.description, scan: file, created_at: Time.utc))
        Created.new(Detail.of(receipt))
      end
    end
  end
end
