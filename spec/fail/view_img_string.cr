require "../../src/punch"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.img src: "/logo.svg", alt: "Logo"
  end
end

Punch::HTMLView.render(Bad.new)
