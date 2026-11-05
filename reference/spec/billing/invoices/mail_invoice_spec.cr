require "../../spec_helper"

# A sent invoice of 2 × 125.00 EUR to a customer at *email*; its number.
private def sent_invoice(client, email : String) : {Billing::Invoices::ID, String}
  customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email}).json["customer"]["id"].as_s
  created = client.post(Billing::Invoices::Create.path,
    json: {customer_id: customer, currency: "EUR", lines: [{description: "Consulting", quantity: 2, unit_price: 12_500}]})
  id = InvoicingSpec.parse(Billing::Invoices::ID, created.json["invoice"]["id"].as_s)
  sent = client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key)
  sent.status.should eq(HTTP::Status::OK)
  {id, sent.json["number"].as_s}
end

private def unique_email : String
  "billing-#{Random::Secure.hex(6)}@example.org"
end

describe "sending an invoice" do
  it "mails it to the customer through the outbox, with a link to it" do
    client = AccountsSpec.client
    email = unique_email
    _, number = sent_invoice(client, email)
    Punch::Spec.mails.should be_empty # not before the job runs

    -> { Punch::Spec.perform_jobs.map(&.type).should eq(["Billing::Invoices::MailInvoice(Billing::InvoiceSent)"]) }
      .should deliver_mail(Billing::Invoices::InvoiceMail, to: email, times: 1)
    mail = Punch::Spec.mails(to: email).first
    mail.subject.should eq("Invoice #{number} from Example Consulting GmbH")
    mail.from.should eq(%("Example Consulting" <invoices@example.org>))
    mail.to.should eq([%("Ada Lovelace" <#{email}>)])
    mail.locale.should eq("en")
    mail.text.should contain("Dear Ada Lovelace,\n\nplease find invoice #{number} of €250.00, due on ")
    mail.html.value.should contain("<p>Dear Ada Lovelace,</p>")
    link = mail.paths.first? || fail "no link in #{mail.text}"
    mail.text.should contain("View invoice #{number} <#{Punch.public_url}#{link}>")
  end

  it "links to the invoice, which opens without signing in" do
    client = AccountsSpec.client
    email = unique_email
    id, number = sent_invoice(client, email)
    Punch::Spec.perform_jobs
    mail = Punch::Spec.mails(to: email).first
    link = mail.paths.first? || fail "no link in #{mail.text}"
    shared = Punch::Spec.client.get(link)
    shared.status.should eq(HTTP::Status::OK)
    shared.json["number"].should eq(number)
    shared.json["id"].should eq(id.to_s)
    Punch::Spec.client.visit(link).should have_element("h1", text: /#{number}/)
  end

  it "mails in the customer's language, else in the organization's" do
    client = AccountsSpec.client
    german = unique_email
    customer = client.post(Billing::Customers::Create.path, json: {name: "Grete Müller", email: german, locale: "de"})
    customer.json["customer"]["locale"].should eq("de")
    created = client.post(Billing::Invoices::Create.path,
      json: {customer_id: customer.json["customer"]["id"], currency: "EUR", lines: [{description: "Beratung", quantity: 2, unit_price: 12_500}]})
    client.post(Billing::Invoices::Send.path(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, created.json["invoice"]["id"].as_s)), headers: Punch::Spec.idempotency_key)
    Punch::Spec.perform_jobs
    mail = Punch::Spec.mails(to: german).first
    mail.locale.should eq("de")
    mail.subject.should start_with("Rechnung ")
    mail.text.should contain("über 250,00 €")

    # No language for the customer: the organization's, its founder's
    # when it was founded.
    Punch::Spec.db.write do |db|
      organizations = Accounts::Organizations::Table
      organization = organizations.find(db, InvoicingSpec.parse(Accounts::Organizations::ID, customer.json["customer"]["organization_id"].as_i64)) || raise "no organization"
      organizations.update(db, organization.copy_with(locale: InvoicingSpec.parse(Punch::LocaleTag, "de")))
    end
    other = unique_email
    sent_invoice(client, other)
    Punch::Spec.perform_jobs
    Punch::Spec.mails(to: other).first.locale.should eq("de")
  end
end
