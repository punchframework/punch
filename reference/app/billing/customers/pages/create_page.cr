module Billing::Customers
  # The fields a customer is made of, for adding and for editing.
  struct NewView
    include Punch::Component

    def initialize(@actor : Invoicing::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.customers
      v.render Invoicing::Layout.new(t.new_customer, @actor) do
        v.h1 t.new_customer
        v.form(Create.action, idempotent: true) do |form|
          form.field :name, label: t.contact_person
          form.field :company_name, hint: t.company_hint
          form.field :email
          form.field :address, as: :textarea, label: t.address, hint: t.address_hint
          form.field :tax_id, label: t.tax_id, hint: t.tax_id_hint
          form.field :locale, as: :select, options: Invoicing::Languages.options, label: t.mail_language, hint: t.mail_language_hint
          form.submit t.add
        end
      end
    end
  end

  # The form that adds a customer: `GET /billing/customers/new`.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct CreatePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = NewView

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      NewView.new(actor)
    end

    def self.redirect(result : Created) : Punch::Href
      IndexPage.href
    end
  end
end
