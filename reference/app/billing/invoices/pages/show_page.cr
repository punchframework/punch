module Billing::Invoices
  @[Punch::Status(200)]
  struct DetailView
    include Punch::Component

    def initialize(@detail : Detail, @actor : Invoicing::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.invoices
      title = Invoices.title(v.locale, @detail.number, @detail.id)
      v.render Invoicing::Layout.new(title, @actor, morph: true) do
        v.h1 title
        v.dl(class: "facts") do
          v.dt t.customer
          if billed_to = @detail.billed_to
            v.render AddressLines.new(billed_to.lines)
          else
            v.dd t.unknown_customer
          end
          if sender = @detail.sender
            v.dt t.from
            v.render AddressLines.new(sender.lines)
          end
          v.dt t.status
          v.dd Invoices.state(v.locale, @detail.status, @detail.overdue?)
          v.render Dates.new(@detail)
        end
        v.p t.draft_note if @detail.status.draft?
        v.render LinesTable.new(@detail)
        if @detail.status.draft?
          v.div(class: "actions") do
            v.form(Send.action(invoice_id: @detail.id)) { |form| form.submit t.send }
            v.form(Destroy.action(invoice_id: @detail.id), class: "danger", data: {turbo_confirm: t.delete_confirm}) { |form| form.submit t.delete }
          end
        end
      end
    end
  end

  # One invoice, as `Show` answers it. A draft can be sent or deleted from
  # here; a refusal (a draft without lines) shows this page again with
  # the reason. Agents read it too, as markdown with the two forms as
  # action blocks. Open in a browser, it shows a change made elsewhere
  # (sent, paid, revised, deleted) by refreshing itself.
  @[Punch::AgentReadable]
  @[Punch::Authorize(ByRole)]
  @[Punch::Forms(Send, Destroy)]
  struct ShowPage < Punch::Page
    alias Input = Show::Input

    alias Output = DetailView | NotFound

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      case detail = Show.new.call(input, db, actor)
      in NotFound then detail
      in Detail   then DetailView.new(detail, actor)
      end
    end

    def live(event : InvoiceChanged, input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Punch::TurboStream?
      Punch::TurboStream.build(&.refresh) if event.invoice_id == input.invoice_id
    end

    # After a deleted draft, the list; after sending, this page again.
    def self.redirect(result : Nil) : Punch::Href
      IndexPage.href
    end
  end
end
