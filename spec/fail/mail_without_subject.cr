require "../../src/punch"

struct Welcome
  include Punch::Mail

  def to : Punch::Mail::Address
    Punch::Mail::Address.new(Punch::Email.parse("ada@example.org").as(Punch::Email))
  end

  def view(v : Punch::View) : Nil
    v.p "Welcome"
  end
end

Punch::Mailer.render(Welcome.new, Punch::I18n.default)
