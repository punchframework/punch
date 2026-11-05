require "../../src/punch"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.p("Total", id: 42.5.to_f32.to_s.chars)
  end
end

Punch::HTMLView.render(Bad.new)
