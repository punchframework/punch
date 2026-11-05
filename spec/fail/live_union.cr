require "../../src/punch"

module Reports
  struct Changed
    include Punch::Event

    def initialize
    end
  end

  struct Component
    include Punch::Component

    def view(v : Punch::View) : Nil
      v.h1 "Report"
    end
  end

  struct Other
    include Punch::Event

    def initialize
    end
  end

  @[Punch::Public]
  struct IndexPage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Component
      Component.new
    end

    def live(event : Changed | Other, input : Input, db : Punch::Reader) : Punch::TurboStream?
    end
  end
end

Punch::Routing.routes
