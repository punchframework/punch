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

# Two users, each administrator of an organization of their own, and
# clients signed in as them.
private def two_users
  ada, bob = AccountsSpec.user("Ada Admin"), AccountsSpec.user("Bob Member")
  organization = Punch::Spec.db.read { |db| AccountsSpec.organization(db, ada.id) }
  {ada, bob, organization, Punch::Spec.client.sign_in(ada.id), Punch::Spec.client.sign_in(bob.id)}
end

describe "roles" do
  it "lets a member see invoices but not send them or add customers: 403, with the role on the trace" do
    _, bob, organization, ada_client, bob_client = two_users
    id = start_draft(ada_client, add_customer(ada_client))
    AccountsSpec.give(bob.id, :member, on: organization)
    bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization))

    bob_client.get(Billing::Invoices::Show.path(invoice_id: id)).status.should eq(HTTP::Status::OK)
    sent = bob_client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key)
    expect_forbidden(sent)
    sent.trace.root["punch.roles"].should eq("accounts.roles.member")
    expect_forbidden(bob_client.post(Billing::Customers::Create.path, json: {name: "Eve", email: "eve@example.org"}))
  end

  it "shows a member no button their role does not permit, and an editor the Send button" do
    _, bob, organization, ada_client, bob_client = two_users
    id = start_draft(ada_client, add_customer(ada_client))
    AccountsSpec.give(bob.id, :member, on: organization)
    bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization))

    page = bob_client.visit(Billing::Invoices::ShowPage.href(invoice_id: id))
    page.status.should eq(HTTP::Status::OK)
    page.should_not have_element("button", text: "Send invoice")
    page.should_not have_element("button", text: "Delete draft")
    bob_client.visit(Home::IndexPage.href).should_not have_element("a", text: "New invoice")
    bob_client.submit(Billing::Invoices::Send.action(invoice_id: id)).status.should eq(HTTP::Status::FORBIDDEN)

    AccountsSpec.give(bob.id, :editor, on: organization)
    bob_client.visit(Billing::Invoices::ShowPage.href(invoice_id: id)).should have_element("button", text: "Send invoice")
  end

  it "lets an editor open the new invoice form and send, which a member may not" do
    _, bob, organization, ada_client, bob_client = two_users
    id = start_draft(ada_client, add_customer(ada_client))
    AccountsSpec.give(bob.id, :member, on: organization)
    bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization))
    bob_client.visit(Billing::Invoices::CreatePage.href).status.should eq(HTTP::Status::FORBIDDEN)

    AccountsSpec.give(bob.id, :editor, on: organization)
    bob_client.visit(Billing::Invoices::CreatePage.href).status.should eq(HTTP::Status::OK)
    bob_client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key).status.should eq(HTTP::Status::OK)
  end

  it "counts an expired role nowhere" do
    _, bob, organization, ada_client, bob_client = two_users
    id = start_draft(ada_client, add_customer(ada_client))
    Punch::Spec.db.write do |db|
      Punch::Roles.assign(db, bob.id, Accounts::Roles::Member, on: organization, expires_at: 1.second.ago)
    end
    expect_not_found(bob_client.get(Billing::Invoices::Show.path(invoice_id: id)))
    expect_not_found(bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization)))
  end
end
