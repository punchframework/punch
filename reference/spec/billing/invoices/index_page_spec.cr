require "../../spec_helper"

private def customer(client, name = "Ada Lovelace") : String
  client.post(Billing::Customers::Create.path, json: {name: name, email: "#{Random.new.hex(4)}@example.org"}).json["customer"]["id"].as_s
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

private def list(filter = Billing::Invoices::Queries::Page::Filter.new) : Punch::Href
  Billing::Invoices::IndexPage.href(filter: filter)
end

private def status(value : Billing::Invoices::Invoice::Status) : Billing::Invoices::Queries::Page::Filter
  Billing::Invoices::Queries::Page::Filter.new(status: value)
end

private def refresh?(message : String) : Bool
  message.includes?(%(<turbo-stream action="refresh">))
end

describe "invoice pages" do
  it "lists invoices a page at a time, linking each" do
    client = AccountsSpec.client
    ada = customer(client)
    ids = Array.new(3) { invoice(client, ada) }
    first = client.visit(Billing::Invoices::IndexPage.href(limit: Punch::PageSize.of(2)))
    first.should have_element("table.invoices tbody tr", count: 2)
    first.should have_element("tbody a[href='#{Billing::Invoices::ShowPage.href(invoice_id: ids[0])}']", text: "Draft #{ids[0]}")
    token = client.get(Billing::Invoices::Index.path, query: {limit: 2}).json["next_after"].as_s
    after = Billing::Invoices::Queries::Page::Cursor.parse(token).as(Billing::Invoices::Queries::Page::Cursor)
    # Sealed, since invoice IDs are public: each token for a position differs.
    first.should have_element("a[rel=next][href^='/billing/invoices?after='][href*='&limit=2']", text: "Next page")
    second = client.visit(Billing::Invoices::IndexPage.href(after: after, limit: Punch::PageSize.of(2)))
    second.should have_element("tbody tr", count: 1)
    second.should_not have_element("a[rel=next]")

    # The cursor holds the position only; the next link repeats the filter.
    drafts_only = Billing::Invoices::Queries::Page::Filter.new(status: :draft)
    drafts = client.visit(Billing::Invoices::IndexPage.href(filter: drafts_only, limit: Punch::PageSize.of(2)))
    drafts.should have_element("a[rel=next][href^='/billing/invoices?filter%5Bstatus%5D=draft&after='][href*='&limit=2']")
    # The filter form shows the filter and starts a new one at the first page.
    drafts.should have_element("form.filter[method=get][action='/billing/invoices'] select[name='filter[status]'] option[value=draft][selected]")
    drafts.should have_element("form.filter input[name=limit][type=hidden][value='2']")
    drafts.should_not have_element("form.filter [name=after]")
  end

  it "marks overdue invoices in the list" do
    client = AccountsSpec.client
    id = invoice(client, customer(client), send: true)
    Punch::Spec.db.write(&.exec("UPDATE invoices SET due_at = '2020-01-01T00:00:00.000000000Z' WHERE id = ?", id.value))
    client.visit(Billing::Invoices::IndexPage.href).should have_element("tr.invoice.overdue td", text: "overdue")
  end

  it "asks for sign-in and rejects a bad page size with a problem page" do
    visitor = Punch::Spec.client.visit(Billing::Invoices::IndexPage.href)
    visitor.should redirect_to(Accounts::Sessions::CreatePage.href)
    invalid = AccountsSpec.client.visit("#{Billing::Invoices::IndexPage.href}?limit=500")
    invalid.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    invalid.should have_element("li", text: "limit: Is out of range. out_of_range")
  end
end

describe "the invoice list, open in a browser" do
  it "is live, and morphs when Turbo refreshes it" do
    watching, _, customer, _ = windows
    id = draft(watching, customer)
    page = watching.visit(list)
    page.should have_element("body > turbo-stream-source[src^='/billing/invoices?_live=']")
    page.should have_element(%(head meta[name="turbo-refresh-method"][content="morph"]))
    page.should have_element("tbody tr##{Punch.dom_id(id)}")
    Punch::Routing.routes.find!(&.operation.==("Billing::Invoices::IndexPage")).surfaces.should contain("live")
  end

  it "replaces the row of an invoice sent in another window" do
    watching, acting, customer, _ = windows
    id = draft(acting, customer)
    live = watching.live(list)
    number = send(acting, id)
    message = live.next
    message.should have_stream_action(:replace, id, containing: "tr##{Punch.dom_id(id)} a", text: "Invoice #{number}")
    message.should have_stream_action(:replace, id, containing: "td", text: "sent")
    message.should contain(%(method="morph"))
    live.close
  end

  it "replaces a revised draft's row, and removes a deleted one" do
    watching, acting, customer, _ = windows
    id = draft(acting, customer)
    live = watching.live(list)
    acting.patch(Billing::Invoices::Update.path(invoice_id: id), json: {lines: [{description: "Workshop", quantity: 1, unit_price: 99_000}]})
      .status.should eq(HTTP::Status::OK)
    live.next.should have_stream_action(:replace, id, containing: "td", text: "€990.00")
    acting.delete(Billing::Invoices::Destroy.path(invoice_id: id)).status.should eq(HTTP::Status::NO_CONTENT)
    live.next.should have_stream_action(:remove, id)
    live.close
  end

  it "refreshes for a new draft that it would list, and not for one it would not" do
    watching, acting, customer, _ = windows
    live = watching.live(list)
    draft(acting, customer)
    refresh?(live.next).should be_true
    sent_only = watching.live(list(status(:sent)))
    draft(acting, customer)
    refresh?(live.next).should be_true
    sent_only.next?.should be_nil
    live.close
    sent_only.close
  end

  it "removes a sent invoice from the drafts, and refreshes the sent list it now belongs to" do
    watching, acting, customer, _ = windows
    id = draft(acting, customer)
    drafts = watching.live(list(status(:draft)))
    sent = watching.live(list(status(:sent)))
    send(acting, id)
    drafts.next.should have_stream_action(:remove, id)
    refresh?(sent.next).should be_true
    drafts.close
    sent.close
  end

  it "refreshes a search that the new number may now match" do
    watching, acting, customer, _ = windows
    id = draft(acting, customer)
    search = watching.live(list(Billing::Invoices::Queries::Page::Filter.new(q: Punch::LikeText.new("INV"))))
    send(acting, id)
    refresh?(search.next).should be_true
    search.close
  end

  it "shows a payment that arrives by webhook while it is open" do
    watching, acting, customer, _ = windows
    id = draft(acting, customer)
    number = send(acting, id)
    Punch::Spec.perform_jobs
    live = watching.live(list)
    body = {event: "payment.succeeded", data: {payment_id: "pay_live", invoice_number: number, amount: 25_000, currency: "EUR", paid_at: "2026-10-19T09:30:00Z"}}.to_json
    Punch::Spec.client.deliver_webhook(Billing::Payments::Provider::Receive.path, body, secret: BillingSpec::WEBHOOK_SECRET)
      .status.should eq(HTTP::Status::NO_CONTENT)
    live.next?.should be_nil # processed by a job, not at delivery
    Punch::Spec.perform_jobs
    live.next.should have_stream_action(:replace, id, containing: "td", text: "paid")
    live.close
  end

  it "hears nothing of another organization's invoices" do
    watching, _, _, _ = windows
    _, stranger, strangers_customer, _ = windows
    live = watching.live(list)
    id = draft(stranger, strangers_customer)
    send(stranger, id)
    stranger.delete(Billing::Invoices::Destroy.path(invoice_id: draft(stranger, strangers_customer)))
    live.next?.should be_nil
    live.close
  end
end

describe "an agent and a browser" do
  it "sends a draft by markdown while the open list shows it" do
    watching, _, customer, user = windows
    id = draft(watching, customer)
    live = watching.live(list)
    headers = Punch::Spec.bearer(Punch::Spec.api_token(user))
    agent = Punch::Spec.client
    page = agent.read(Billing::Invoices::ShowPage.href(invoice_id: id), headers: headers)
    agent.act(page, "Send invoice", headers: headers).should redirect_to(Billing::Invoices::ShowPage.href(invoice_id: id).markdown_url)
    live.next.should have_stream_action(:replace, id, containing: "td", text: "sent")
    live.close
  end
end
