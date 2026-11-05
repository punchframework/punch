module Billing::Receipts
  # Hands out an upload of one scan to a signed-in user: where to send the
  # file, and the ticket that later names it. Each user gets 60 an hour.
  # A grant is a few short fields, so its body is limited too: input is
  # parsed before the user is known.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimit(60, per: 1.hour, by: :actor)]
  @[Punch::BodyLimit(8 * 1024)]
  struct UploadScan < Punch::Command
    struct Input
      include Punch::Input

      getter size : Int64
      getter content_type : String
      # What the file is called on the user's machine.
      getter filename : Punch::Upload::Filename?
    end

    alias Output = Punch::Upload::Grant | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(UploadScan)) : Output
      Punch::Upload.grant(db, Scan, size: input.size, content_type: input.content_type, filename: input.filename, owner: actor.user.id.to_s)
    end
  end
end
