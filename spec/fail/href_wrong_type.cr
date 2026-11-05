require "../../src/punch"

struct View
  include Punch::Component

  def view(v : Punch::View) : Nil
  end
end

module Notes
  @[Punch::Public]
  struct IndexPage < Punch::Page
    struct Input
      include Punch::Input
      getter page : Int32 = 1
      getter tag : String
    end

    def call(input : Input, db : Punch::Reader) : View
      View.new
    end
  end
end

Notes::IndexPage.href(tag: "a", page: "2")
