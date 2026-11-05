require "../../spec_helper"

private def create(client, email = "ada@example.org", company_name : String? = nil)
  client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email, company_name: company_name})
end

describe "customers API" do
  it "changes only the fields given" do
    client = AccountsSpec.client
    id = InvoicingSpec.parse(Billing::Customers::ID, create(client).json["customer"]["id"].as_s)
    create(client, "grace@example.org")
    path = Billing::Customers::Update.path(customer_id: id)

    response = client.patch(path, json: {company_name: "Engines Ltd"})
    response.status.should eq(HTTP::Status::OK)
    {response.json["name"], response.json["display_name"], response.json["email"]}.should eq({"Ada Lovelace", "Engines Ltd", "ada@example.org"})

    taken = client.patch(path, json: {email: "grace@example.org"})
    taken.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    taken.json["errors"][0]["code"].should eq("taken")
    client.patch(path, json: {email: "ada@example.org"}).status.should eq(HTTP::Status::OK)
    client.patch(Billing::Customers::Update.path(customer_id: InvoicingSpec.parse(Billing::Customers::ID, 99)), json: {name: "X"}).status.should eq(HTTP::Status::NOT_FOUND)
  end
end
