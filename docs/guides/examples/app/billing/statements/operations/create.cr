module Billing::Statements
  # A new statement: its ID alone, since a client's idempotency key keeps
  # this answer as it is. `Show` has the rest.
  @[Punch::Status(201)]
  record Created,
    id : ID do
    include JSON::Serializable
  end

  # Saves a statement with the file its ticket names, private from here on.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter document : Punch::Upload::Ticket
    end

    alias Output = Created | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      case file = Punch::Upload.claim(db, input.document, Document, owner: actor.user.id.to_s)
      in Punch::Invalid then Punch::Rejection.new(Punch::Rejection::Path{"document"}, file)
      in Punch::Upload::File
        statement = Punch.cannot_violate(Table.insert(db, user_id: actor.user.id, file: Punch::Upload::PrivateFile.of(file), created_at: Time.utc))
        Created.new(statement.id)
      end
    end
  end
end
