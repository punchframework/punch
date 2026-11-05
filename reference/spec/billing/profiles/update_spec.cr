require "../../spec_helper"

private ADDRESS = {street: "Hauptstraße 1", postal_code: "10115", city: "Berlin", country: "Germany"}

describe "billing profile API" do
  it "sets the organization's address, a group of columns, and changes it" do
    client = AccountsSpec.client
    client.get(Billing::Profiles::Show.path).status.should eq(HTTP::Status::NOT_FOUND)

    set = client.patch(Billing::Profiles::Update.path, json: ADDRESS)
    set.status.should eq(HTTP::Status::OK)
    set.json["address"].should eq(JSON.parse(ADDRESS.to_json))
    moved = client.patch(Billing::Profiles::Update.path, json: ADDRESS.merge(city: "Hamburg", postal_code: "20095"))
    moved.json["address"]["city"].should eq("Hamburg")
    client.get(Billing::Profiles::Show.path).json["address"]["postal_code"].should eq("20095")

    Punch::Spec.db.read do |db|
      db.query_all("SELECT address_city, address_country FROM billing_profiles") { |row| {row.read(String), row.read(String)} }
    end.should eq([{"Hamburg", "Germany"}])
    client.patch(Billing::Profiles::Update.path, json: ADDRESS.merge(city: "")).json["errors"][0]["path"].should eq(JSON.parse(%(["city"])))
  end

  it "is set by administrators; members and editors only read it" do
    admin = AccountsSpec.user
    organization = Punch::Spec.db.read { |db| AccountsSpec.organization(db, admin.id) }
    editor = Punch::Spec.db.write { |db| Accounts::Users::Table.insert(db, name: InvoicingSpec.parse(Punch::NonEmptyString, "Eda"), created_at: Time.utc) }
    AccountsSpec.give(editor.id, :editor, on: organization)
    Punch::Spec.client.sign_in(admin.id).patch(Billing::Profiles::Update.path, json: ADDRESS).status.should eq(HTTP::Status::OK)

    client = Punch::Spec.client.sign_in(editor.id)
    client.get(Billing::Profiles::Show.path).json["address"]["city"].should eq("Berlin")
    client.patch(Billing::Profiles::Update.path, json: ADDRESS).status.should eq(HTTP::Status::FORBIDDEN)
  end
end

describe "billing profile form" do
  it "sets the address in a form filled with it, and invoices show it as their sender" do
    client = AccountsSpec.client
    client.visit(Billing::Profiles::UpdatePage.href).should have_element("form input[name=street]")
    client.submit(Billing::Profiles::Update.action, form: ADDRESS.to_h.transform_keys(&.to_s)).should redirect_to(Billing::Profiles::UpdatePage.href)
    client.visit(Billing::Profiles::UpdatePage.href).should have_element("input[name=city][value=Berlin]")

    customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: "ada@example.org"}).json["customer"]["id"].as_s
    invoice = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Consulting", quantity: 1, unit_price: 100}]}).json["invoice"]["id"].as_s
    page = client.visit(Billing::Invoices::ShowPage.href(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, invoice)))
    page.should have_element("dl.facts dd", text: "Hauptstraße 110115 BerlinGermany") # lines split by <br>
    client.get(Billing::Invoices::Show.path(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, invoice))).json["sender"]["city"].should eq("Berlin")
  end
end
