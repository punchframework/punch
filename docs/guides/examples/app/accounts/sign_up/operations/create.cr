module Accounts::SignUp
  @[Punch::Status(201)]
  record SignedUp,
    user_id : Users::ID do
    include JSON::Serializable
  end

  # Creates a user with an email identity and a password, and mails a link
  # to verify the address (`EmailAdded`). They sign in once they have
  # followed it: until then nobody has shown that the address is theirs,
  # and someone else may have typed it (lib/punch/docs/auth.md).
  # The password is hashed before the transaction opens. The language the
  # browser asked for becomes the user's.
  @[Punch::Public]
  @[Punch::RateLimit(10, per: 1.hour, by: :ip)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter name : Punch::NonEmptyString
      getter email : Punch::Email
      getter password : Punch::Auth::NewPassword
    end

    alias Output = SignedUp | Punch::Auth::EmailIdentities::EmailTaken

    def call(input : Input, db : Punch::Writer, locale : Punch::Locale, events : Punch::Events(EmailAdded)) : Output
      tag = Punch::LocaleTag.parse(locale.code).as?(Punch::LocaleTag)
      now = Time.utc
      user = Users::Table.insert(db, name: input.name, created_at: now, locale: tag)
      # A taken address rolls the new user back with it (lib/punch/docs/queries.md).
      identity = Punch::Auth::EmailIdentities.add(db, user.id, input.email)
      return identity if identity.is_a?(Punch::Auth::EmailIdentities::EmailTaken)

      Punch::Auth::Passwords.set(db, user.id, input.password.hashed)
      events.publish(EmailAdded.new(user.id.value, identity.email))
      SignedUp.new(user.id)
    end
  end
end
