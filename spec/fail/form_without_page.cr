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
    v.form(Notes::Create.action) { |form| form.field :title }
  end
end

Punch::HTMLView.render(NoteForm.new)
