require "../../spec_helper"

private def customer(client, name = "Ada Lovelace", address : String? = nil) : String
  client.post(Billing::Customers::Create.path, json: {name: name, email: "#{Random.new.hex(4)}@example.org", address: address}).json["customer"]["id"].as_s
end

private def invoice(client, customer : String, lines = [{description: "Consulting", quantity: 3, unit_price: 12_500}], send = false) : Billing::Invoices::ID
  raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines}).json["invoice"]["id"].as_s
  id = InvoicingSpec.parse(Billing::Invoices::ID, raw)
  client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key) if send
  id
end

# Two windows of one user: the one that watches and the one that acts.
# A fresh hub, so no example sees another's events.
private def windows : {Punch::Spec::Client, Punch::Spec::Client, Billing::Customers::ID, Accounts::Users::ID}
  Punch::Live.hub = Punch::Live::InProcess.new
  user = AccountsSpec.user
  customer = Punch::Spec.db.write { |db| BillingSpec.customer(db, organization: AccountsSpec.organization(db, user.id)) }
  {Punch::Spec.client.sign_in(user.id), Punch::Spec.client.sign_in(user.id), customer.id, user.id}
end

private def draft(client, customer : Billing::Customers::ID, lines = [{description: "Consulting", quantity: 2, unit_price: 12_500}]) : Billing::Invoices::ID
  created = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines})
  created.status.should eq(HTTP::Status::CREATED)
  InvoicingSpec.parse(Billing::Invoices::ID, created.json["invoice"]["id"].as_s)
end

private def send(client, id : Billing::Invoices::ID) : String
  sent = client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key)
  sent.status.should eq(HTTP::Status::OK)
  sent.json["number"].as_s
end

private def refresh?(message : String) : Bool
  message.includes?(%(<turbo-stream action="refresh">))
end

describe "invoice pages" do
  it "shows a sent invoice with its customer, dates, lines, and total" do
    client = AccountsSpec.client
    id = invoice(client, customer(client), [{description: "Consulting <on site>", quantity: 3, unit_price: 12_500}, {description: "Travel", quantity: 1, unit_price: 4_550}], send: true)
    page = client.visit(Billing::Invoices::ShowPage.href(invoice_id: id))
    page.status.should eq(HTTP::Status::OK)
    page.should have_element("title", text: "Invoice INV-000001")
    page.should have_element("main > h1", text: "Invoice INV-000001")
    page.should have_element("dl.facts dd", text: "Ada Lovelace")
    page.should have_element("dl.facts dd", text: "sent")
    page.should have_element("dl.facts dd time[datetime]", count: 2)
    page.should have_element("table.lines tbody tr", count: 2)
    page.should have_element("table.lines td", text: "Consulting <on site>")
    page.should have_element("table.lines caption", text: "2 lines")
    page.should have_element("table.lines td", text: "€125.00")
    page.should have_element("table.lines tfoot td", text: "€420.50")
    page.should have_element("header nav a[href='/billing/invoices']", text: "Invoices")
    page.should have_element("header strong", text: "Ingrid Iversen")
  end

  it "shows the customer's address below its name, decrypted, a line each" do
    client = AccountsSpec.client
    id = invoice(client, customer(client, address: "12 St James's Square\nLondon SW1Y 4JH"))
    page = client.visit(Billing::Invoices::ShowPage.href(invoice_id: id))
    page.should have_element("dl.facts dd br", count: 2)
    page.body.should contain("Ada Lovelace<br>12 St James&#39;s Square<br>London SW1Y 4JH")
  end

  it "says when an invoice is a draft, and answers 404 for an unknown one" do
    client = AccountsSpec.client
    id = invoice(client, customer(client))
    page = client.visit(Billing::Invoices::ShowPage.href(invoice_id: id))
    page.should have_element("h1", text: "Draft #{id}")
    page.should have_element("p", text: /gets its number when it is sent/)
    page.should_not have_element("time")
    missing = client.visit(Billing::Invoices::ShowPage.href(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, 999_999)))
    missing.status.should eq(HTTP::Status::NOT_FOUND)
    missing.should have_element("code", text: "not_found")
  end
end

describe "an invoice's page, open in a browser" do
  it "refreshes when that invoice changes elsewhere, and only then" do
    watching, acting, customer, _ = windows
    id, other = draft(acting, customer), draft(acting, customer)
    watching.visit(Billing::Invoices::ShowPage.href(invoice_id: id))
      .should have_element(%(head meta[name="turbo-refresh-method"][content="morph"]))
    live = watching.live(Billing::Invoices::ShowPage.href(invoice_id: id))
    send(acting, other)
    live.next?.should be_nil
    send(acting, id)
    refresh?(live.next).should be_true
    live.close
  end
end

describe "assets" do
  it "asks before deleting a draft" do
    client = AccountsSpec.client
    customer = client.post(Billing::Customers::Create.path, json: {name: "Ada", email: "ada@example.org"}).json["customer"]["id"].as_s
    raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Work", quantity: 1, unit_price: 100}]}).json["invoice"]["id"].as_s
    page = client.visit(Billing::Invoices::ShowPage.href(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, raw)))
    page.should have_element("form.danger[data-turbo-confirm='Delete this draft?']")
  end
end
