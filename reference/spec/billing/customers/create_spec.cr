require "../../spec_helper"

private def create(client, email = "ada@example.org", company_name : String? = nil)
  client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email, company_name: company_name})
end

private def unique_email : String
  "billing-#{Random::Secure.hex(6)}@example.org"
end

describe "customers API" do
  it "creates a customer and shows it" do
    client = AccountsSpec.client
    response = create(client, "Ada@Example.org", "Analytical Engines Ltd")
    response.status.should eq(HTTP::Status::CREATED)
    customer = response.json["customer"]
    customer["email"].should eq("ada@example.org")
    customer["display_name"].should eq("Analytical Engines Ltd")

    id = InvoicingSpec.parse(Billing::Customers::ID, customer["id"].as_s)
    shown = client.get(Billing::Customers::Show.path(customer_id: id))
    shown.status.should eq(HTTP::Status::OK)
    shown.json.should eq(customer)
  end

  it "stores the postal address encrypted and shows it decrypted" do
    client = AccountsSpec.client
    response = client.post(Billing::Customers::Create.path, json: {name: "Ada", email: unique_email, address: "12 St James's Square\nLondon"})
    response.json["customer"]["address"].should eq("12 St James's Square\nLondon")
    customer_id = InvoicingSpec.parse(Billing::Customers::ID, response.json["customer"]["id"].as_s)
    stored = Punch::Spec.db.read { |db| db.query_one?("SELECT address FROM customers WHERE id = ?", customer_id.value) { |row| row.read(Bytes?) } }
    stored.should be_encrypted_for("customers", "address")
    String.new(stored || fail "no address").should_not contain("London")

    client.patch(Billing::Customers::Update.path(customer_id: customer_id), json: {name: "Ada Lovelace"}).json["address"].should eq("12 St James's Square\nLondon")
    client.patch(Billing::Customers::Update.path(customer_id: customer_id), json: {address: "Ockham Park"}).json["address"].should eq("Ockham Park")
  end

  it "refuses a second customer with the same email address, in any case" do
    client = AccountsSpec.client
    create(client)
    response = create(client, "ADA@example.org")
    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.json["errors"].should eq(JSON.parse(%([{"path": ["email"], "code": "taken", "params": {}, "message": "Is already taken."}])))
  end

  it "collects every input error" do
    response = AccountsSpec.client.post(Billing::Customers::Create.path, json: {name: " ", email: "not an address"})
    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.json["errors"].as_a.map { |error| {error["path"][0].as_s, error["code"].as_s} }.should eq([{"name", "blank"}, {"email", "invalid_email"}])
  end
end

describe "sending an invoice" do
  it "refuses a language the app does not offer" do
    response = AccountsSpec.client.post(Billing::Customers::Create.path, json: {name: "Ada", email: unique_email, locale: "fr"})
    response.status.code.should eq(422)
    response.json["errors"][0]["code"].should eq("unsupported_locale")
  end
end
