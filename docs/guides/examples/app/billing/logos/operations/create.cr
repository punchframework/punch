module Billing::Logos
  # A logo with what a page needs to lay it out, and no link: a client's
  # idempotency key keeps this answer longer than a link lasts.
  @[Punch::Status(201)]
  record Created,
    id : ID,
    alt : Punch::NonEmptyString?,
    width : Int64?,
    height : Int64? do
    include JSON::Serializable
  end

  # Saves a logo with the file its ticket names. The client measured the
  # image, so its size is what the client says; the alt text is the user's.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter picture : Punch::Upload::Ticket
      getter alt : Punch::NonEmptyString?
      getter width : Int64?
      getter height : Int64?
    end

    alias Output = Created | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      file = Punch::Upload.claim(db, input.picture, Picture, owner: actor.user.id.to_s)
      return Punch::Rejection.new(Punch::Rejection::Path{"picture"}, file) if file.is_a?(Punch::Invalid)

      image = Punch::Upload::ImageFile.of(file, alt: input.alt, width: input.width, height: input.height)
      return Punch::Rejection.new(Punch::Rejection::Path{"picture"}, image) if image.is_a?(Punch::Invalid)

      logo = Punch.cannot_violate(Table.insert(db, user_id: actor.user.id, image: image))
      Created.new(logo.id, image.alt, image.width, image.height)
    end
  end
end
