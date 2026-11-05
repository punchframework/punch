require "../../src/punch"

# A component that writes raw HTML outside chrome has no markdown form, so
# it cannot be on a page agents read.
struct Chart
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.raw Punch::SafeHTML.trusted("<svg></svg>")
  end
end

module Reports
  @[Punch::AgentReadable]
  @[Punch::Public]
  struct IndexPage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Chart
      Chart.new
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
