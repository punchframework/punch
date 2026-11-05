require "../../spec_helper"

private LINES = [
  {description: "Consulting", quantity: 3, unit_price: 12_500},
  {description: "Travel", quantity: 1, unit_price: 4_990},
]

private def customer_id(client, email = "ada@example.org") : String
  client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email}).json["customer"]["id"].as_s
end

private def invoice_id(raw) : Billing::Invoices::ID
  InvoicingSpec.parse(Billing::Invoices::ID, raw.as_s)
end

private def draft(client, customer : String, lines = LINES) : Billing::Invoices::ID
  response = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines})
  response.status.should eq(HTTP::Status::CREATED)
  invoice_id(response.json["invoice"]["id"])
end

private def customer(client, name = "Ada Lovelace", email = "ada@example.org") : Billing::Customers::ID
  raw = client.post(Billing::Customers::Create.path, json: {name: name, email: email}).json["customer"]["id"].as_s
  InvoicingSpec.parse(Billing::Customers::ID, raw)
end

private def draft(client, customer : Billing::Customers::ID, lines = [{description: "Consulting", quantity: 3, unit_price: 12_500}]) : Billing::Invoices::ID
  raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines}).json["invoice"]["id"].as_s
  InvoicingSpec.parse(Billing::Invoices::ID, raw)
end

describe "invoices API" do
  it "keeps who a sent invoice bills, so a later edit of the customer changes no sent invoice" do
    client = AccountsSpec.client
    customer = customer_id(client)
    invoice = draft(client, customer)
    # A draft bills the customer as they are now.
    client.get(Billing::Invoices::Show.path(invoice_id: invoice)).json["billed_to"]["name"].should eq("Ada Lovelace")

    sent = client.post(Billing::Invoices::Send.path(invoice_id: invoice), headers: Punch::Spec.idempotency_key)
    sent.json["billed_to"]["name"].should eq("Ada Lovelace")
    client.patch(Billing::Customers::Update.path(customer_id: InvoicingSpec.parse(Billing::Customers::ID, customer)), json: {name: "Ada King"}).status.should eq(HTTP::Status::OK)
    client.get(Billing::Invoices::Show.path(invoice_id: invoice)).json["billed_to"]["name"].should eq("Ada Lovelace")
    client.get(Billing::Invoices::Show.path(invoice_id: draft(client, customer))).json["billed_to"]["name"].should eq("Ada King")
    Punch::Spec.db.read { |db| db.query_one?("SELECT typeof(billed_to) FROM invoices", &.read(String)) }.should eq("blob")
  end

  it "sends a draft once, numbering invoices in sending order" do
    client = AccountsSpec.client
    customer = customer_id(client)
    first, second = draft(client, customer), draft(client, customer)

    sent = client.post(Billing::Invoices::Send.path(invoice_id: second), headers: Punch::Spec.idempotency_key)
    sent.status.should eq(HTTP::Status::OK)
    {sent.json["status"], sent.json["number"]}.should eq({"sent", "INV-000001"})
    (Time.parse_rfc3339(sent.json["due_at"].as_s) - Time.parse_rfc3339(sent.json["sent_at"].as_s)).should eq(14.days)
    sent.trace.should have_span("Billing::Invoices::Queries.last_sequence")
    sent.headers["RateLimit"].should eq(%("billing.invoices.send.actor";r=29;t=120))
    client.post(Billing::Invoices::Send.path(invoice_id: first), headers: Punch::Spec.idempotency_key).json["number"].should eq("INV-000002")

    again = client.post(Billing::Invoices::Send.path(invoice_id: second), headers: Punch::Spec.idempotency_key)
    again.status.should eq(HTTP::Status::CONFLICT)
    {again.json["code"], again.json["number"]}.should eq({"already_sent", "INV-000001"})
  end

  it "sends once under one idempotency key and gives a retry the same answer, and refuses a send without a key" do
    client = AccountsSpec.client
    id = draft(client, customer_id(client))
    missing = client.post(Billing::Invoices::Send.path(invoice_id: id))
    missing.status.should eq(HTTP::Status::BAD_REQUEST)
    missing.json["code"].should eq("idempotency_key_required")

    send = -> { client.twice("POST", Billing::Invoices::Send.path(invoice_id: id)) }
    send.should enqueue(Billing::Invoices::Remind, invoice_id: id, times: 1)
    Punch::Spec.perform_jobs.size.should eq(1)
    Punch::Spec.mails.size.should eq(1)
    # A new key is a new attempt: the invoice is sent already.
    client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key).json["code"].should eq("already_sent")
  end

  it "replays the answer under a key, not the invoice as it is now" do
    client = AccountsSpec.client
    id = draft(client, customer_id(client))
    first, again = client.twice("POST", Billing::Invoices::Send.path(invoice_id: id), key: "send-1")
    first.status.should eq(HTTP::Status::OK)
    again.should be_replay_of(first)
    first.json["number"].should eq("INV-000001")
    reused = client.post(Billing::Invoices::Send.path(invoice_id: draft(client, customer_id(client, "bob@example.org"))),
      headers: Punch::Spec.idempotency_key("send-1"))
    reused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    reused.json["code"].should eq("idempotency_key_reused")
  end

  it "does not send a draft without lines, and numbers nothing" do
    client = AccountsSpec.client
    customer = customer_id(client)
    empty = draft(client, customer, [] of NamedTuple(description: String, quantity: Int32, unit_price: Int32))
    response = client.post(Billing::Invoices::Send.path(invoice_id: empty), headers: Punch::Spec.idempotency_key)
    {response.status, response.json["code"]}.should eq({HTTP::Status::UNPROCESSABLE_ENTITY, "no_lines"})
    client.post(Billing::Invoices::Send.path(invoice_id: draft(client, customer)), headers: Punch::Spec.idempotency_key).json["number"].should eq("INV-000001")
  end
end

describe "invoice forms" do
  it "sends a draft from its page, and says why one without lines cannot be" do
    client = AccountsSpec.client
    ada = customer(client)
    id = draft(client, ada)
    page = client.visit(Billing::Invoices::ShowPage.href(invoice_id: id))
    page.should have_element(".actions form[action='/billing/invoices/#{id}/send'] button", text: "Send invoice")

    client.submit(Billing::Invoices::Send.action(invoice_id: id)).should redirect_to(Billing::Invoices::ShowPage.href(invoice_id: id))
    sent = client.visit(Billing::Invoices::ShowPage.href(invoice_id: id))
    sent.should have_element("h1", text: "Invoice INV-000001")
    sent.should_not have_element(".actions")

    empty = draft(client, ada, [] of NamedTuple(description: String, quantity: Int32, unit_price: Int32))
    refused = client.submit(Billing::Invoices::Send.action(invoice_id: empty))
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.should have_element("form[action='/billing/invoices/#{empty}/send'] .form-errors li[data-code=no_lines]",
      text: "A draft needs at least one line before it is sent.")
    refused.should have_element("h1", text: "Draft #{empty}")
  end
end
