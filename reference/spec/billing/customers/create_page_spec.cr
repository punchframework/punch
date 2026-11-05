require "../../spec_helper"

private def customer(client, name = "Ada Lovelace", email = "ada@example.org") : Billing::Customers::ID
  raw = client.post(Billing::Customers::Create.path, json: {name: name, email: email}).json["customer"]["id"].as_s
  InvoicingSpec.parse(Billing::Customers::ID, raw)
end

describe "customer forms" do
  it "adds a customer from the form and leads back to the list" do
    client = AccountsSpec.client
    form = client.visit(Billing::Customers::CreatePage.href)
    form.should have_element("form[action='/billing/customers'] input[name=name][required]")
    form.should have_element("label", text: "Contact person")
    form.should have_element("input[name=company_name][aria-describedby*=hint]")
    form.should have_element("p.field-hint", text: /addressed to the company/)

    response = client.submit(Billing::Customers::Create.action, form: {"name" => "Grace Hopper", "company_name" => "", "email" => "grace@example.org"})
    response.should redirect_to(Billing::Customers::IndexPage.href)
    list = client.visit(Billing::Customers::IndexPage.href)
    list.should have_element("table.customers td", text: "grace@example.org")
    list.should have_element("table.customers a", text: "Grace Hopper")
  end

  it "adds one customer when the form is sent twice, by its idempotency key" do
    client = AccountsSpec.client
    form = client.visit(Billing::Customers::CreatePage.href)
    key = form.html.find("form[action='/billing/customers'] input[type=hidden][name=_idempotency_key]").first["value"]
    fields = {"name" => "Grace Hopper", "email" => "grace@example.org", Punch::IdempotencyKeys::FIELD => key}
    first = client.submit(Billing::Customers::Create.action, form: fields)
    first.should redirect_to(Billing::Customers::IndexPage.href)
    client.submit(Billing::Customers::Create.action, form: fields).should be_replay_of(first)
    client.get(Billing::Customers::Index.path).json["customers"].as_a.size.should eq(1)
  end

  it "shows the form again with what was sent and why it was refused" do
    client = AccountsSpec.client
    customer(client)
    refused = client.submit(Billing::Customers::Create.action, form: {"name" => " ", "email" => "Ada@Example.org"})
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.should have_field_error("name", "blank")
    refused.should have_element("input[name=email][value='Ada@Example.org']")

    taken = client.submit(Billing::Customers::Create.action, form: {"name" => "Ada", "email" => "Ada@Example.org"})
    taken.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    taken.should have_field_error("email", "taken")
    taken.should have_element("input[name=name][value=Ada]")
  end
end
