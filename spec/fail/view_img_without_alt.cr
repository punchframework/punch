require "../../src/punch"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.img src: Punch::Href.external("https://example.org/logo.png")
  end
end

Punch::HTMLView.render(Bad.new)
