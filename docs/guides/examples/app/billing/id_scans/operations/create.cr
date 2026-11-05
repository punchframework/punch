module Billing::IdScans
  @[Punch::Status(201)]
  record Created,
    id_scan : Detail do
    include JSON::Serializable
  end

  # Saves an ID scan with the photo its ticket names. It answers without
  # the name or alt text, since a client's idempotency key would keep the
  # answer as it is.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter photo : Punch::Upload::Ticket
      getter alt : Punch::NonEmptyString?
    end

    alias Output = Created | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      file = Punch::Upload.claim(db, input.photo, Photo, owner: actor.user.id.to_s)
      return Punch::Rejection.new(Punch::Rejection::Path{"photo"}, file) if file.is_a?(Punch::Invalid)

      photo = Punch::Upload::PrivateImageFile.of(file, alt: input.alt)
      return Punch::Rejection.new(Punch::Rejection::Path{"photo"}, photo) if photo.is_a?(Punch::Invalid)

      Created.new(Detail.of(Punch.cannot_violate(Table.insert(db, user_id: actor.user.id, photo: photo))))
    end
  end
end
