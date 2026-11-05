module Billing::Profiles
  @[Punch::Status(200)]
  struct EditView
    include Punch::Component

    def initialize(@profile : Profile?, @actor : Invoicing::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.profiles
      v.render Invoicing::Layout.new(t.title, @actor) do
        v.h1 t.title
        v.p t.intro
        address = @profile.try(&.address)
        values = {street: address.try(&.street), postal_code: address.try(&.postal_code), city: address.try(&.city), country: address.try(&.country)}
        v.form(Update.action, values: values) do |form|
          form.field :street, label: t.street
          form.field :postal_code, label: t.postal_code
          form.field :city, label: t.city
          form.field :country, label: t.country
          form.submit t.save
        end
      end
    end
  end

  # The form that sets the organization's billing profile.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  @[Punch::Forms(Update)]
  struct UpdatePage < Punch::Page
    alias Input = Show::Input

    alias Output = EditView

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      profile = Show.new.call(input, db, actor)
      EditView.new(profile.as?(Profile), actor)
    end

    def self.redirect(result : Profile) : Punch::Href
      UpdatePage.href
    end
  end
end
