module Billing::Receipts
  struct NewView
    include Punch::Component

    def initialize(@actor : Examples::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.receipts
      v.render Examples::Layout.new(t.new_receipt, @actor) do
        v.h1 t.new_receipt
        v.form(Create.action) do |form|
          form.field :description
          form.field :scan, accept: Scan.upload_accept, data: {punch_upload: UploadScan.path}
          form.submit t.save
        end
      end
    end
  end

  # The form that saves a receipt: `GET /billing/receipts/new`. Choosing a
  # file sends it to the storage; the form itself carries only the ticket.
  @[Punch::Authorize(Punch::SignedIn)]
  struct CreatePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = NewView

    def call(input : Input, db : Punch::Reader, actor : Examples::Actor) : Output
      NewView.new(actor)
    end

    def self.redirect(result : Created) : Punch::Href
      ShowPage.href(receipt_id: result.receipt.id)
    end
  end
end
