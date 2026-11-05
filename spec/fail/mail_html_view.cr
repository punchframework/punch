require "../../src/punch"

# A mail's view takes a plain Punch::View: its text part has no `raw`.
struct Welcome
  include Punch::Mail

  def to : Punch::Mail::Address
    Punch::Mail::Address.new(Punch::Email.parse("ada@example.org").as(Punch::Email))
  end

  def subject(locale : Punch::Locale) : String
    "Welcome"
  end

  def view(v : Punch::HTMLView) : Nil
    v.raw Punch::SafeHTML.trusted("<b>hi</b>")
  end
end

Punch::Mailer.render(Welcome.new, Punch::I18n.default)
