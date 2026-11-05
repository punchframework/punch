require "../../src/punch"

Punch.assets "../assets/fixture"

struct Bad
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.document("Bad", stylesheets: {Punch.asset("images/logo.svg")}) { }
  end
end

Punch::HTMLView.render(Bad.new)
