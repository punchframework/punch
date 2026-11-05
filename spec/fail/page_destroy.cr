require "../../src/punch"

struct View
  include Punch::Component

  def view(v : Punch::View) : Nil
  end
end

module Notes
  @[Punch::Public]
  struct DestroyPage < Punch::Page
    struct Input
      include Punch::Input
      @[Punch::PathParam]
      getter note_id : Int64
    end

    def call(input : Input, db : Punch::Reader) : View
      View.new
    end
  end
end

Punch::Routing.routes
