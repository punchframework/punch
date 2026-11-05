module Billing::Receipts
  @[Punch::Status(200)]
  struct DetailView
    include Punch::Component

    def initialize(@receipt : Record, @actor : Examples::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.receipts
      v.render Examples::Layout.new(@receipt.description.to_s, @actor) do
        v.h1 @receipt.description.to_s
        if link = Punch::Upload.href?(@receipt.scan, download: true)
          v.p { v.a @receipt.scan.filename.to_s, href: link }
        end
        v.form(Destroy.action(receipt_id: @receipt.id)) { |form| form.submit t.delete }
      end
    end
  end

  # One receipt, with a link that fetches its scan from the storage. Only
  # the user who keeps it gets here, so the link reaches no one else.
  @[Punch::Authorize(Own)]
  @[Punch::Forms(Destroy)]
  struct ShowPage < Punch::Page
    alias Input = Show::Input

    alias Output = DetailView | NotFound

    def call(input : Input, db : Punch::Reader, actor : Examples::Actor) : Output
      receipt = Table.find(db, input.receipt_id)
      receipt ? DetailView.new(receipt, actor) : NotFound.new
    end

    # After a deleted receipt, a new one.
    def self.redirect(result : Nil) : Punch::Href
      CreatePage.href
    end
  end
end
