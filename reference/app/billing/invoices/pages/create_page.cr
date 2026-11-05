module Billing::Invoices
  # The form that starts a draft: a customer, a currency, and lines, with
  # empty rows to fill in. Empty rows are left out when it is sent.
  struct NewView
    include Punch::Component

    BLANK_LINES = 3

    def initialize(@customers : Array(Customers::Customer), @customer_id : Customers::ID?, @actor : Invoicing::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.invoices
      v.render Invoicing::Layout.new(t.new_invoice, @actor) do
        v.h1 t.new_invoice
        if @customers.empty?
          v.p do
            v.text "#{t.add_customer_first} "
            v.a t.new_customer, href: Customers::CreatePage.href
          end
          next
        end
        currency = Punch::Currency.parse("EUR").as(Punch::Currency)
        v.form(Create.action, values: {customer_id: @customer_id, currency: currency}, idempotent: true) do |form|
          form.field :customer_id, as: :select, options: @customers.map { |customer| {customer.id, customer.display_name} }
          form.field :currency, hint: t.currency_hint
          v.table(class: "lines") do
            v.thead do
              v.tr do
                v.th t.description, scope: "col"
                v.th t.quantity, scope: "col"
                v.th t.unit_price_cents, scope: "col"
              end
            end
            v.tbody do
              form.each(:lines, LineInput, blank: BLANK_LINES) do |line, index|
                v.tr do
                  v.td do
                    line.control :description, aria: {label: t.line_description(line: index + 1)}
                    line.errors :description
                  end
                  v.td do
                    line.control :quantity, aria: {label: t.line_quantity(line: index + 1)}
                    line.errors :quantity
                  end
                  v.td do
                    line.control :unit_price, aria: {label: t.line_unit_price(line: index + 1)}
                    line.errors :unit_price
                  end
                end
              end
            end
          end
          form.submit t.create_draft
        end
      end
    end
  end

  # `GET /billing/invoices/new`, optionally for one customer.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct CreatePage < Punch::Page
    struct Input
      include Punch::Input

      getter customer_id : Customers::ID?
    end

    alias Output = NewView

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      customers = Customers::Queries.page(db, organization_id: actor.organization_id, order: :name, limit: 100).map { |record| Customers::Customer.new(record) }
      NewView.new(customers, input.customer_id, actor)
    end

    def self.redirect(result : Created) : Punch::Href
      ShowPage.href(invoice_id: result.invoice.id)
    end
  end
end
