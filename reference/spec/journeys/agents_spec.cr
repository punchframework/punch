require "../spec_helper"

# An agent working for a user with an API token: it reads the invoice
# pages as markdown and acts through their action blocks (lib/punch/docs/views.md).
private def agent : {Punch::Spec::Client, HTTP::Headers, Billing::Customers::ID}
  user = AccountsSpec.user
  headers = Punch::Spec.bearer(Punch::Spec.api_token(user.id))
  customer = Punch::Spec.db.write { |db| BillingSpec.customer(db, organization: AccountsSpec.organization(db, user.id)) }
  {Punch::Spec.client, headers, customer.id}
end

private def draft(client, headers, customer : Billing::Customers::ID, lines = [{description: "Consulting", quantity: 3, unit_price: 12_500}]) : Billing::Invoices::ID
  created = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines}, headers: headers)
  InvoicingSpec.parse(Billing::Invoices::ID, created.json["invoice"]["id"].as_s)
end

describe "agents" do
  it "find a draft through the list's filter and send it from its page" do
    client, headers, customer = agent
    id = draft(client, headers, customer)
    list = client.read(Billing::Invoices::IndexPage.href, headers: headers)
    list.content_type.should eq("text/markdown")
    list.should have_action("Filter", operation: "billing.invoices.index_page")
    drafts = client.act(list, "Filter", {"filter[status]" => "draft"}, headers: headers)
    drafts.body.should contain("(/billing/invoices/#{id}.md)")

    page = client.read(Billing::Invoices::ShowPage.href(invoice_id: id), headers: headers)
    page.should have_action("Send invoice", operation: "billing.invoices.send")
    page.should have_action("Delete draft", operation: "billing.invoices.destroy")
    send = Punch::Spec.actions(page.body).find!(&.title.==("Send invoice"))
    # Send requires an idempotency key: the block carries one to reuse.
    send.fixed.keys.should eq([Punch::IdempotencyKeys::FIELD])
    send.text.should contain("at most 30 per 1 h per user")

    sent = client.act(page, "Send invoice", headers: headers)
    sent.should redirect_to(Billing::Invoices::ShowPage.href(invoice_id: id).markdown_url)
    after = client.read(sent.headers["Location"], headers: headers)
    after.should_not have_action("Send invoice")
    after.body.should contain("- Status: sent")
  end

  # An agent given only the base URL and a token, and no `Accept` header:
  # every step goes by the `.md` URLs.
  it "start at /llms.txt and send a draft by its links alone" do
    client, headers, customer = agent
    id = draft(client, headers, customer)
    headers["Accept"] = "*/*"
    llms = client.get("/llms.txt")
    llms.body.should start_with("# Invoicing\n\n> Invoices and customers of the organization you work in.")
    entry = llms.body[/- \[Invoices\]\(([^)]+)\)/, 1]
    entry.should eq("/billing/invoices.md")
    list = client.get(entry, headers: headers)
    list.content_type.should eq("text/markdown")
    page = client.get(list.body[%r{\((/billing/invoices/#{id}\.md)\)}, 1], headers: headers)
    page.content_type.should eq("text/markdown")
    sent = client.act(page, "Send invoice", headers: headers)
    sent.should redirect_to("/billing/invoices/#{id}.md")
    client.get(sent.headers["Location"], headers: headers).body.should contain("- Status: sent")
  end

  it "find the markdown named in the HTML of an agent-readable page" do
    client, headers, customer = agent
    id = draft(client, headers, customer)
    client.visit(Billing::Invoices::ShowPage.href(invoice_id: id), headers: headers)
      .should have_element(%(link[rel="alternate"][type="text/markdown"][href="/billing/invoices/#{id}.md"]))
  end

  it "read why a draft cannot be sent" do
    client, headers, customer = agent
    id = draft(client, headers, customer, [] of NamedTuple(description: String, quantity: Int32, unit_price: Int32))
    page = client.read(Billing::Invoices::ShowPage.href(invoice_id: id), headers: headers)
    refused = client.act(page, "Send invoice", headers: headers)
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.content_type.should eq("text/markdown")
    refused.body.should contain("Problem: A draft needs at least one line before it is sent. (`no_lines`)")
  end

  it "see no actions on another organization's invoice" do
    client, headers, customer = agent
    id = draft(client, headers, customer)
    _, stranger, _ = agent
    page = client.read(Billing::Invoices::ShowPage.href(invoice_id: id), headers: stranger)
    page.status.should eq(HTTP::Status::NOT_FOUND)
    Punch::Spec.actions(page.body).should be_empty
  end
end
