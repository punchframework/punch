require "../../src/punch"

module Notes
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
      getter title : String
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end
end

struct NoteForm
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.p "x"
  end
end

module Notes
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end

  @[Punch::Forms(Index)]
  @[Punch::Public]
  struct ListPage < Punch::Page
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : NoteForm
      NoteForm.new
    end
  end
end

Punch::Routing.routes.first.handler
