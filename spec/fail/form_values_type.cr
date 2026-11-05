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

@[Punch::Public]
struct Notes::CreatePage < Punch::Page
  struct Input
    include Punch::Input
  end

  def call(input : Input, db : Punch::Reader) : NoteForm
    NoteForm.new
  end
end

struct NoteForm
  include Punch::Component

  def view(v : Punch::View) : Nil
    v.form(Notes::Create.action, values: {title: 1}) { }
  end
end

Punch::HTMLView.render(NoteForm.new)
