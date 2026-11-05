module Billing::Invoices
  # What the recipient of a shared link sees: the issuer, the number, the
  # dates, and the lines, without navigation.
  @[Punch::Status(200)]
  struct SharedView
    include Punch::Component

    def initialize(@detail : Detail)
    end

    def view(v : Punch::View) : Nil
      t = v.t.invoices
      title = Invoices.title(v.locale, @detail.number, @detail.id)
      v.render Invoicing::Layout.new(title) do
        v.h1 title
        v.p do
          v.text "#{t.from} "
          v.strong @detail.issuer.name.to_s
          if vat_id = @detail.issuer.vat_id
            v.text " (#{t.vat_id(id: vat_id.to_s)})"
          end
        end
        v.dl(class: "facts") { v.render Dates.new(@detail) }
        v.render LinesTable.new(@detail)
      end
    end
  end

  # The page behind a shared link, without sign-in. Limited per address, so
  # guessing links is slow (the signature makes it hopeless anyway).
  @[Punch::Public]
  @[Punch::RateLimit(60, per: 1.minute, by: :ip)]
  struct SharedPage < Punch::Page
    alias Input = Shared::Input

    alias Output = SharedView | NotFound

    def call(input : Input, db : Punch::Reader) : Output
      case detail = Shared.new.call(input, db)
      in NotFound then detail
      in Detail   then SharedView.new(detail)
      end
    end
  end
end
