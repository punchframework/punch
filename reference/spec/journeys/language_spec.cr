require "../spec_helper"

describe "the interface's language" do
  it "follows the browser's Accept-Language, with German amounts and dates" do
    client = AccountsSpec.client
    client.language = "de-DE,de;q=0.9,en;q=0.5"
    customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: "ada@example.org"}).json["customer"]["id"].as_s
    client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Beratung", quantity: 10, unit_price: 12_500}]})

    page = client.visit(Billing::Invoices::IndexPage.href)
    page.should have_element("html[lang=de]")
    page.should have_element("main > h1", text: "Rechnungen")
    page.should have_element("header nav a", text: "Kunden")
    page.should have_element("tr.invoice td", text: "1.250,00 €")
    page.should have_element("tr.invoice td", text: "Entwurf")
    page.headers["Content-Language"].should eq("de")
    page.headers["Vary"].should contain("Accept-Language")

    client.language = "en"
    client.visit(Billing::Invoices::IndexPage.href).should have_element("tr.invoice td", text: "€1,250.00")
  end

  it "answers API clients' rejections in their language" do
    client = AccountsSpec.client
    response = client.post(Billing::Customers::Create.path, json: {name: "", email: "nope"}, headers: HTTP::Headers{"Accept-Language" => "de"})
    response.json["detail"].should eq("Einige Eingaben sind ungültig.")
    response.json["errors"].as_a.map(&.["message"].as_s).should eq(["Darf nicht leer sein.", "Ist keine E-Mail-Adresse."])
  end
end
