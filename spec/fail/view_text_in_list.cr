require "../../src/punch"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.ul "Items"
  end
end

Punch::HTMLView.render(Bad.new)
