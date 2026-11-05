module Accounts::Language
  # Stores the language the user chose for the interface (lib/punch/docs/translations.md); it
  # wins over the browser's Accept-Language from the next request on.
  # Without a choice, the browser's language decides again.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Update < Punch::Command
    struct Input
      include Punch::Input

      getter locale : Punch::LocaleTag?
    end

    alias Output = Punch::Rejection?

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, grant : Punch::Grant(Update)) : Output
      tag = input.locale
      if rejection = Examples::Languages.check(tag)
        return rejection
      end

      Users::Table.update(db, actor.user.copy_with(locale: tag))
      nil
    end
  end
end
