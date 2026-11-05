require "../../src/punch"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.a "Home", href: "/"
  end
end

Punch::HTMLView.render(Bad.new)
