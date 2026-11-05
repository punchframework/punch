require "../../src/punch"

struct View
  include Punch::Component

  def view(v : Punch::View) : Nil
  end
end

module Notes
  @[Punch::Public]
  struct Show < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : View
      View.new
    end
  end
end

Punch::Routing.routes
