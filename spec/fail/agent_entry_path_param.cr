require "../../src/punch"

module Reports
  struct Component
    include Punch::Component

    def view(v : Punch::View) : Nil
      v.h1 "Report"
    end
  end

  # An entry point in /llms.txt is opened from its path alone.
  @[Punch::AgentReadable(entry: true)]
  @[Punch::Public]
  struct ShowPage < Punch::Page
    struct Input
      include Punch::Input
      @[Punch::PathParam]
      getter report_id : Int64
    end

    def call(input : Input, db : Punch::Reader) : Component
      Component.new
    end
  end
end

Punch::Routing.routes
