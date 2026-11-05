require "../../spec_helper"

private def customer(client, name = "Ada Lovelace", email = "ada@example.org") : Billing::Customers::ID
  raw = client.post(Billing::Customers::Create.path, json: {name: name, email: email}).json["customer"]["id"].as_s
  InvoicingSpec.parse(Billing::Customers::ID, raw)
end

private def draft(client, customer : Billing::Customers::ID, lines = [{description: "Consulting", quantity: 3, unit_price: 12_500}]) : Billing::Invoices::ID
  raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines}).json["invoice"]["id"].as_s
  InvoicingSpec.parse(Billing::Invoices::ID, raw)
end

describe "customer forms" do
  it "edits a customer in a form filled with its values" do
    client = AccountsSpec.client
    id = customer(client)
    form = client.visit(Billing::Customers::UpdatePage.href(customer_id: id))
    form.should have_element("form[action='/billing/customers/#{id}?_method=PATCH'] input[name=email][value='ada@example.org']")
    form.should have_element("input[name=name][value='Ada Lovelace']")

    client.submit(Billing::Customers::Update.action(customer_id: id), {company_name: InvoicingSpec.parse(Punch::NonEmptyString, "Analytical Engines Ltd")})
      .should redirect_to(Billing::Customers::IndexPage.href)
    client.get(Billing::Customers::Show.path(customer_id: id)).json["display_name"].should eq("Analytical Engines Ltd")
    client.visit(Billing::Customers::UpdatePage.href(customer_id: InvoicingSpec.parse(Billing::Customers::ID, 999))).status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "loads the customer's invoices into a frame with the same ID" do
    client = AccountsSpec.client
    id = customer(client)
    draft(client, id)
    frame_id = Punch.dom_id(id, "invoices")
    edit = client.visit(Billing::Customers::UpdatePage.href(customer_id: id))
    edit.should have_element("turbo-frame##{frame_id}[loading=lazy][src='#{Billing::Invoices::IndexPage.href(filter: Billing::Invoices::Queries::Page::Filter.new(customer_id: id))}'] a")
    list = client.visit(Billing::Invoices::IndexPage.href(filter: Billing::Invoices::Queries::Page::Filter.new(customer_id: id)))
    list.should have_element("turbo-frame##{frame_id}[target=_top] tbody tr", count: 1)
  end
end
