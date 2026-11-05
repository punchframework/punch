require "../spec_helper"

private def add_customer(client, email = "ada@example.org", name = "Ada Lovelace") : Billing::Customers::ID
  response = client.post(Billing::Customers::Create.path, json: {name: name, email: email})
  response.status.should eq(HTTP::Status::CREATED)
  InvoicingSpec.parse(Billing::Customers::ID, response.json["customer"]["id"].as_s)
end

private def start_draft(client, customer : Billing::Customers::ID) : Billing::Invoices::ID
  response = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Consulting", quantity: 3, unit_price: 12_500}]})
  response.status.should eq(HTTP::Status::CREATED)
  InvoicingSpec.parse(Billing::Invoices::ID, response.json["invoice"]["id"].as_s)
end

private def expect_not_found(response : Punch::Spec::Response) : Nil
  {response.status, response.json["code"]}.should eq({HTTP::Status::NOT_FOUND, "not_found"})
end

private def expect_forbidden(response : Punch::Spec::Response) : Nil
  {response.status, response.json["code"]}.should eq({HTTP::Status::FORBIDDEN, "forbidden"})
end

private def ids(response : Punch::Spec::Response, key : String) : Array(String)
  response.json[key].as_a.map(&.["id"].as_s)
end

# Two users, each administrator of an organization of their own, and
# clients signed in as them.
private def two_users
  ada, bob = AccountsSpec.user("Ada Admin"), AccountsSpec.user("Bob Member")
  organization = Punch::Spec.db.read { |db| AccountsSpec.organization(db, ada.id) }
  {ada, bob, organization, Punch::Spec.client.sign_in(ada.id), Punch::Spec.client.sign_in(bob.id)}
end

describe "organizations" do
  it "hides another organization's customers, in lists and by ID" do
    ada, bob = AccountsSpec.client, AccountsSpec.client
    id = add_customer(ada)
    add_customer(bob, "bob@example.org", "Bob Builder")

    bob.get(Billing::Customers::Index.path).json["customers"].as_a.map(&.["email"]).should eq(["bob@example.org"])
    bob.get(Billing::Customers::Search.path, query: {q: "Ada"}).json["customers"].as_a.should be_empty
    shown = bob.get(Billing::Customers::Show.path(customer_id: id))
    expect_not_found(shown)
    shown.json["code"].should eq(bob.get(Billing::Customers::Show.path(customer_id: InvoicingSpec.parse(Billing::Customers::ID, 999))).json["code"])
    shown.trace.should have_span("Billing::Customers::Queries.organization")
    shown.trace.root["punch.roles"].should eq("none")
    expect_not_found(bob.get(Billing::Customers::Statement.path(customer_id: id)))
    expect_not_found(bob.patch(Billing::Customers::Update.path(customer_id: id), json: {name: "Mallory"}))
    ada.get(Billing::Customers::Show.path(customer_id: id)).json["name"].should eq("Ada Lovelace")
  end

  it "keeps email addresses unique per organization, not across them" do
    ada, bob = AccountsSpec.client, AccountsSpec.client
    add_customer(ada)
    add_customer(bob) # the same address, another organization
    taken = ada.post(Billing::Customers::Create.path, json: {name: "Ada", email: "Ada@Example.org"})
    {taken.status, taken.json["code"]}.should eq({HTTP::Status::UNPROCESSABLE_ENTITY, "invalid_input"})
    taken.json["errors"][0]["path"].should eq(JSON.parse(%(["email"])))
  end

  it "hides another organization's invoices and refuses to touch them" do
    ada, bob = AccountsSpec.client, AccountsSpec.client
    adas = add_customer(ada)
    id = start_draft(ada, adas)

    bob.get(Billing::Invoices::Index.path).json["invoices"].as_a.should be_empty
    bob.get(Billing::Invoices::Index.path, query: {filter: {customer_id: adas}}).json["invoices"].as_a.should be_empty
    expect_not_found(bob.get(Billing::Invoices::Show.path(invoice_id: id)))
    expect_not_found(bob.get(Billing::Invoices::Link.path(invoice_id: id)))
    expect_not_found(bob.patch(Billing::Invoices::Update.path(invoice_id: id), json: {currency: "CHF"}))
    sent = bob.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key)
    expect_not_found(sent)
    sent.trace.should_not have_span("Billing::Invoices::Queries.last_sequence")
    bob.delete(Billing::Invoices::Destroy.path(invoice_id: id)).status.should eq(HTTP::Status::NOT_FOUND)

    invoice = ada.get(Billing::Invoices::Show.path(invoice_id: id)).json
    {invoice["status"], invoice["currency"]}.should eq({"draft", "EUR"})
  end

  it "starts drafts only for customers of the organization worked in" do
    ada, bob, organization, ada_client, bob_client = two_users
    adas = add_customer(ada_client)
    refused = bob_client.post(Billing::Invoices::Create.path, json: {customer_id: adas, currency: "EUR"})
    {refused.status, refused.json["code"]}.should eq({HTTP::Status::UNPROCESSABLE_ENTITY, "unknown_customer"})

    # As an editor of Ada's organization, but working in his own, Bob
    # still cannot: drafts go into the organization he works in.
    AccountsSpec.give(bob.id, :editor, on: organization)
    refused = bob_client.post(Billing::Invoices::Create.path, json: {customer_id: adas, currency: "EUR"})
    refused.json["code"].should eq("unknown_customer")
    Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM invoices", &.read(Int64))).should eq(0)
    bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization)).status.should eq(HTTP::Status::OK)
    start_draft(bob_client, adas)
    ada.should_not be_nil
  end

  it "keeps the organizations of an invoice and its customer equal in the schema" do
    Punch::Spec.db.write do |db|
      adas = BillingSpec.customer(db)
      bobs = BillingSpec.customer(db, "bob@example.org")
      expect_raises(Punch::Database::ConstraintError, /FOREIGN KEY/) do
        Billing::Invoices::Table.insert(db, organization_id: bobs.organization_id, customer_id: adas.id,
          currency: InvoicingSpec.parse(Punch::Currency, "EUR"), status: "draft", created_at: Time.utc)
      end
    end
  end

  it "shows another organization's pages as not found, and offers only its own customers" do
    ada, bob = AccountsSpec.client, AccountsSpec.client
    adas = add_customer(ada)
    id = start_draft(ada, adas)
    add_customer(bob, "bob@example.org")

    bob.visit(Billing::Customers::UpdatePage.href(customer_id: adas)).status.should eq(HTTP::Status::NOT_FOUND)
    bob.visit(Billing::Invoices::ShowPage.href(invoice_id: id)).status.should eq(HTTP::Status::NOT_FOUND)
    bob.visit(Billing::Customers::IndexPage.href).should_not have_element("table.customers td", text: "ada@example.org")
    form = bob.visit(Billing::Invoices::CreatePage.href)
    form.should have_element("select[name=customer_id] option", count: 1)
    form.should_not have_element("select[name=customer_id] option[value='#{adas}']")

    refused = bob.submit(Billing::Invoices::Send.action(invoice_id: id))
    refused.status.should eq(HTTP::Status::NOT_FOUND)
    ada.get(Billing::Invoices::Show.path(invoice_id: id)).json["status"].should eq("draft")
  end

  it "lists only the organization worked in, a full page at a time" do
    _, bob, organization, ada_client, bob_client = two_users
    adas = add_customer(ada_client)
    ada_drafts = Array.new(3) { start_draft(ada_client, adas) }
    bobs = add_customer(bob_client, "bob@example.org")
    bob_drafts = Array.new(3) { start_draft(bob_client, bobs) }
    AccountsSpec.give(bob.id, :member, on: organization)

    first = bob_client.get(Billing::Invoices::Index.path, query: {limit: 2})
    ids(first, "invoices").should eq(bob_drafts.first(2).map(&.to_s))

    bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization)).json["current"].should be_true
    first = bob_client.get(Billing::Invoices::Index.path, query: {limit: 2})
    ids(first, "invoices").should eq(ada_drafts.first(2).map(&.to_s))
    rest = bob_client.get(Billing::Invoices::Index.path, query: {limit: 2, after: first.json["next_after"].as_s})
    ids(rest, "invoices").should eq([ada_drafts[2].to_s])
    bob_client.get(Billing::Customers::Index.path).json["customers"].as_a.map(&.["id"].as_s).should eq([adas.to_s])
    organizations = bob_client.get(Accounts::Organizations::Index.path).json["organizations"].as_a
    organizations.map { |found| {found["name"].as_s, found["current"].as_bool} }.should eq([{"Ada Admin", true}, {"Bob Member", false}])
  end

  it "answers a user without an organization with 403" do
    user = AccountsSpec.user
    Punch::Spec.db.write { |db| db.exec("DELETE FROM punch_role_assignments WHERE user_id = ?", user.id.value) }
    client = Punch::Spec.client.sign_in(user.id)
    expect_forbidden(client.get(Billing::Invoices::Index.path))
    client.get(Accounts::Organizations::Index.path).json["organizations"].as_a.should be_empty
    started = client.post(Accounts::Organizations::Create.path, json: {name: "Fresh Start"})
    started.status.should eq(HTTP::Status::CREATED)
    client.get(Billing::Invoices::Index.path).status.should eq(HTTP::Status::OK)
  end
end
