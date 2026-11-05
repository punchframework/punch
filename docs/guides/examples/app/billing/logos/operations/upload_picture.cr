module Billing::Logos
  # Hands out an upload of one logo to a signed-in user.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimit(60, per: 1.hour, by: :actor)]
  @[Punch::BodyLimit(8 * 1024)]
  struct UploadPicture < Punch::Command
    struct Input
      include Punch::Input

      getter size : Int64
      getter content_type : String
      getter filename : Punch::Upload::Filename?
    end

    alias Output = Punch::Upload::Grant | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(UploadPicture)) : Output
      Punch::Upload.grant(db, Picture, size: input.size, content_type: input.content_type, filename: input.filename, owner: actor.user.id.to_s)
    end
  end
end
