# The languages the app offers, for the forms that choose one, such as the
# interface's (`Accounts::Language::Update`).
module Invoicing::Languages
  # Each locale of the app, named in its own language.
  def self.options : Array({Punch::LocaleTag, String})
    Punch::I18n.catalog.locales.map do |code|
      {Punch::LocaleTag.parse(code).as(Punch::LocaleTag), Punch::I18n.locale(code).translate?("punch.language_name") || code}
    end
  end

  # `unsupported_locale` at *field* when *tag* is not one of the app's
  # locales; `nil` for no tag.
  def self.check(tag : Punch::LocaleTag?, field : String = "locale") : Punch::Rejection?
    return unless tag
    return if Punch::I18n.catalog.locale?(tag.to_s)

    Punch::Rejection.new(Punch::Rejection::Path{field}, Punch::Invalid.new("unsupported_locale"))
  end
end
