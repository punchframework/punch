require "../../src/punch"

# A component that takes an HTMLView may write raw HTML: not on a page
# agents read.
struct Chart
  include Punch::Component

  def view(v : Punch::HTMLView) : Nil
    v.p "chart"
  end
end

struct Report
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.h1 "Report"
    v.render Chart.new
  end
end

module Reports
  @[Punch::AgentReadable]
  @[Punch::Public]
  struct IndexPage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Report
      Report.new
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
