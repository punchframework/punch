require "../spec_helper"

describe "the app in a browser" do
  it "leads from sign-in to a sent invoice and back out" do
    client = Punch::Spec.client
    client.visit(Billing::Customers::IndexPage.href).should redirect_to(Accounts::Sessions::CreatePage.href)
    client.visit(Accounts::Sessions::CreatePage.href).should have_element("a", text: "Create an account")
    AccountsSpec.sign_up(client, "ingrid@example.org", "correct horse battery")
    client.visit(Home::IndexPage.href).should have_element("nav a", text: "Invoices")

    client.submit(Billing::Customers::Create.action, form: {"name" => "Ada Lovelace", "company_name" => "", "email" => "ada@example.org"})
      .should redirect_to(Billing::Customers::IndexPage.href)
    form = client.visit(Billing::Invoices::CreatePage.href)
    adas = form.html.find("select[name=customer_id] option").first["value"]
    created = client.submit(Billing::Invoices::Create.action, form: {
      "customer_id" => adas, "currency" => "EUR",
      "lines[0][description]" => "Consulting", "lines[0][quantity]" => "3", "lines[0][unit_price]" => "12500",
    })
    created.status.should eq(HTTP::Status::SEE_OTHER)
    show = created.headers["Location"]
    page = client.visit(show)
    page.should have_element("button", text: "Send invoice")
    client.submit(Billing::Invoices::Send.action(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, show.split('/').last)))
      .should redirect_to(show)
    client.visit(show).should have_element("h1", text: "Invoice INV-000001")

    client.submit(Accounts::Sessions::SignOut.action).should redirect_to(Accounts::Sessions::CreatePage.href)
    client.visit(show).should redirect_to(Accounts::Sessions::CreatePage.href)
  end
end
