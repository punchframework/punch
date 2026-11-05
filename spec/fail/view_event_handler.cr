require "../../src/punch"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.div(onclick: "alert(1)") { }
  end
end

Punch::HTMLView.render(Bad.new)
