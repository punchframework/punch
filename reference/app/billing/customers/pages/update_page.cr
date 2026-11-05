module Billing::Customers
  @[Punch::Status(200)]
  struct EditView
    include Punch::Component

    def initialize(@customer : Customer, @actor : Invoicing::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.customers
      title = @customer.display_name
      v.render Invoicing::Layout.new(title, @actor) do
        v.h1 title
        values = {name: @customer.name, company_name: @customer.company_name, email: @customer.email, address: @customer.address, tax_id: @customer.tax_id, locale: @customer.locale}
        v.form(Update.action(customer_id: @customer.id), values: values) do |form|
          form.field :name, label: t.contact_person
          form.field :company_name
          form.field :email
          form.field :address, as: :textarea, label: t.address, hint: t.address_hint
          form.field :tax_id, label: t.tax_id, hint: t.tax_id_hint
          form.field :locale, as: :select, options: Invoicing::Languages.options, label: t.mail_language, hint: t.mail_language_hint
          form.submit t.save
        end
        v.h2 t.invoices
        # Loaded by Turbo once it is in view; without it, the link.
        v.frame(@customer.id, "invoices", src: Invoices::IndexPage.href(filter: Invoices::Queries::Page::Filter.new(customer_id: @customer.id)), loading: "lazy", target: "_top") do
          v.p { v.a t.invoices_of(name: title), href: Invoices::IndexPage.href(filter: Invoices::Queries::Page::Filter.new(customer_id: @customer.id)) }
        end
      end
    end
  end

  # The form that edits a customer: `GET /billing/customers/:customer_id/edit`.
  @[Punch::Authorize(ByRole)]
  struct UpdatePage < Punch::Page
    alias Input = Show::Input

    alias Output = EditView | NotFound

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      case customer = Show.new.call(input, db, actor)
      in NotFound then customer
      in Customer then EditView.new(customer, actor)
      end
    end

    def self.redirect(result : Customer) : Punch::Href
      IndexPage.href
    end
  end
end
