require "../../spec_helper"

private def create(client, tax_id : String?, email = "billing-#{Random::Secure.hex(6)}@example.org")
  client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email, tax_id: tax_id})
end

private def stored(column : String, id : Billing::Customers::ID) : Bytes?
  Punch::Spec.db.read { |db| db.query_one?("SELECT #{column} FROM customers WHERE id = ?", id.value) { |row| row.read(Bytes?) } }
end

private def id_of(response) : Billing::Customers::ID
  InvoicingSpec.parse(Billing::Customers::ID, response.json["customer"]["id"].as_s)
end

describe "a customer's tax number" do
  it "is stored encrypted, with its blind index, and shown without spaces" do
    client = AccountsSpec.client
    response = create(client, "de 123 456 789")
    response.json["customer"]["tax_id"].should eq("DE123456789")
    id = id_of(response)
    stored("tax_id", id).should be_encrypted_for("customers", "tax_id")
    String.new(stored("tax_id", id) || fail "no tax number").should_not contain("123456789")
    stored("tax_id_index", id).should eq(Punch::Stored.blind_index(Billing::Customers::TaxID.parse("DE123456789").as(Billing::Customers::TaxID), "customers", "tax_id_index"))
    create(client, nil).json["customer"]["tax_id"]?.should be_nil
  end

  it "differs between an organization's customers, written in any way" do
    client = AccountsSpec.client
    create(client, "DE123456789")
    response = create(client, "de123 456789")
    response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    response.json["errors"].should eq(JSON.parse(%([{"path": ["tax_id"], "code": "taken", "params": {}, "message": "Is already taken."}])))

    customer_id = id_of(create(client, "AT U12345678"))
    client.patch(Billing::Customers::Update.path(customer_id: customer_id), json: {tax_id: "DE 123456789"}).json["errors"][0]["path"].should eq(JSON.parse(%(["tax_id"])))
    # Another organization may have the same number.
    create(AccountsSpec.client, "DE123456789").status.should eq(HTTP::Status::CREATED)
  end

  it "finds the customer in the list, through the blind index" do
    client = AccountsSpec.client
    create(client, "DE111111111")
    wanted = create(client, "DE222222222").json["customer"]["id"].as_s
    found = client.get(Billing::Customers::Index.path, query: {filter: {tax_id: "de 222 222 222"}}).json["customers"].as_a
    found.map(&.["id"].as_s).should eq([wanted])
    client.get(Billing::Customers::Index.path, query: {filter: {tax_id: "DE22222222"}}).json["customers"].as_a.should be_empty
    client.get(Billing::Customers::Index.path, query: {filter: {tax_id: "222"}}).json["errors"][0]["code"].should eq("invalid_tax_id")

    page = client.visit(Billing::Customers::IndexPage.href(filter: Billing::Customers::Queries::Page::Filter.new(tax_id: Billing::Customers::TaxID.parse("DE222222222").as(Billing::Customers::TaxID))))
    page.should have_element("form.filter input[name='filter[tax_id]'][value=DE222222222]")
    page.should have_element("table.customers tbody tr", count: 1)
  end

  it "is still found after the key ring rotates, and hashed under the new key when the customer changes" do
    client = AccountsSpec.client
    id = id_of(create(client, "DE333333333"))
    previous = Punch::KeyRing.current
    begin
      Punch::KeyRing.current = Punch::KeyRing.new([Punch::KeyRing::Key.generate(previous.keys.max_of(&.id) + 1)] + previous.keys)
      client.get(Billing::Customers::Index.path, query: {filter: {tax_id: "DE333333333"}}).json["customers"].as_a.size.should eq(1)
      client.patch(Billing::Customers::Update.path(customer_id: id), json: {name: "Ada King"}).status.should eq(HTTP::Status::OK)
      (stored("tax_id_index", id) || fail "no index")[1, 4].should eq((stored("tax_id", id) || fail "no tax number")[1, 4])
      Punch::KeyRing::BlindIndex.key_id(stored("tax_id_index", id) || fail "no index").should eq(Punch::KeyRing.current.signing.id)
    ensure
      Punch::KeyRing.current = previous
    end
  end
end
