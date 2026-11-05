module Billing::Customers
  struct ListView
    include Punch::Component

    def initialize(@page : Page, @actor : Invoicing::Actor, @next_page : Punch::Href?, @input : Index::Input)
    end

    def view(v : Punch::View) : Nil
      t = v.t.customers
      v.render Invoicing::Layout.new(t.title, @actor) do
        v.h1 t.title
        v.p { v.a t.new_customer, href: CreatePage.href }
        filter_form(v)
        if @page.customers.empty?
          v.p t.none
        else
          v.table(class: "customers") do
            v.thead { v.tr { [t.name, t.contact, t.email].each { |label| v.th label, scope: "col" } } }
            v.tbody do
              @page.customers.each do |customer|
                v.tr do
                  v.td { v.a customer.display_name, href: UpdatePage.href(customer_id: customer.id) }
                  v.td customer.name.to_s
                  v.td customer.email.to_s
                end
              end
            end
          end
        end
        if next_page = @next_page
          v.p { v.a t.next_page, href: next_page, rel: "next" }
        end
      end
    end

    # Finds the customer with a tax number, through its blind index: the
    # whole number, in any spacing or case, never a part of it.
    private def filter_form(v : Punch::View) : Nil
      t = v.t.customers
      v.filter_form(IndexPage, @input, class: "filter") do |form|
        form.fields(:filter, Queries::Page::Filter) do |filter|
          filter.field :tax_id, label: t.tax_id, hint: t.tax_id_search_hint
        end
        form.field :order, as: :hidden
        form.field :limit, as: :hidden
        form.submit t.find
      end
    end
  end

  # The customers, a page at a time: `GET /billing/customers` in a browser.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct IndexPage < Punch::Page
    alias Input = Index::Input

    alias Output = ListView

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      page = Index.new.call(input, db, actor)
      next_page = page.next_after.try { |after| IndexPage.href(filter: input.filter, order: input.order, direction: input.direction, after: after, limit: input.limit) }
      ListView.new(page, actor, next_page, input)
    end
  end
end
