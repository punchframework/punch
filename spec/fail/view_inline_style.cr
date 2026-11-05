require "../../src/punch"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.p("Warning", style: "color: red")
  end
end

Punch::HTMLView.render(Bad.new)
