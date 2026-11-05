require "../../spec_helper"

private def customer(client, name = "Ada Lovelace", email = "ada@example.org") : Billing::Customers::ID
  raw = client.post(Billing::Customers::Create.path, json: {name: name, email: email}).json["customer"]["id"].as_s
  InvoicingSpec.parse(Billing::Customers::ID, raw)
end

private def draft(client, customer : Billing::Customers::ID, lines = [{description: "Consulting", quantity: 3, unit_price: 12_500}]) : Billing::Invoices::ID
  raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines}).json["invoice"]["id"].as_s
  InvoicingSpec.parse(Billing::Invoices::ID, raw)
end

describe "invoice forms" do
  it "starts a draft from the form, leaving empty rows out" do
    client = AccountsSpec.client
    ada = customer(client)
    form = client.visit(Billing::Invoices::CreatePage.href(customer_id: ada))
    form.should have_element("select[name=customer_id] option[value='#{ada}'][selected]", text: "Ada Lovelace")
    form.should have_element("input[name=currency][value=EUR]")
    form.should have_element("table.lines tbody tr", count: 3)
    form.should have_element("input[name='lines[0][quantity]'][type=number][min='1'][max='10000']")

    response = client.submit(Billing::Invoices::Create.action, form: {
      "customer_id" => ada.to_s, "currency" => "EUR",
      "lines[0][description]" => "Design", "lines[0][quantity]" => "2", "lines[0][unit_price]" => "5000",
      "lines[1][description]" => "", "lines[1][quantity]" => "", "lines[1][unit_price]" => "",
      "lines[2][description]" => "Hosting", "lines[2][quantity]" => "1", "lines[2][unit_price]" => "900",
    })
    response.status.should eq(HTTP::Status::SEE_OTHER)
    location = response.headers["Location"]
    page = client.visit(location)
    page.should have_element("table.lines tbody tr", count: 2)
    page.should have_element("table.lines tfoot td", text: "€109.00")
  end

  it "marks the field of the row that was refused" do
    client = AccountsSpec.client
    ada = customer(client)
    response = client.submit(Billing::Invoices::Create.action, form: {
      "customer_id" => ada.to_s, "currency" => "euro",
      "lines[0][description]" => "Design", "lines[0][quantity]" => "0", "lines[0][unit_price]" => "5000",
    })
    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.should have_field_error("currency")
    response.should have_field_error("lines[0][quantity]", "out_of_range")
    response.should have_element("input[name='lines[0][description]'][value=Design]")
    # The sent row, then the empty ones again.
    response.should have_element("table.lines tbody tr", count: 4)
  end
end
