require "../spec_helper"

describe "signing in to the API" do
  it "answers 401 to every billing operation without a session or token" do
    client = Punch::Spec.client
    response = client.get(Billing::Invoices::Index.path)
    response.status.should eq(HTTP::Status::UNAUTHORIZED)
    response.headers["WWW-Authenticate"].should eq("Bearer")
    client.post(Billing::Customers::Create.path, json: {name: "Ada", email: "ada@example.org"}).json["code"].should eq("unauthenticated")
    client.get(Accounts::Users::Me.path).status.should eq(HTTP::Status::UNAUTHORIZED)
  end

  it "refuses a Command from another site's page" do
    client = AccountsSpec.client
    forged = client.post(Billing::Customers::Create.path, json: {name: "Mallory", email: "m@example.org"},
      headers: HTTP::Headers{"Origin" => "https://evil.example", "Host" => "invoicing.example"})
    forged.status.should eq(HTTP::Status::FORBIDDEN)
    forged.json["code"].should eq("cross_origin_request")
    client.get(Billing::Customers::Index.path).json["customers"].as_a.should be_empty
  end
end
