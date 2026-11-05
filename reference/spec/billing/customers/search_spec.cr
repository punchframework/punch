require "../../spec_helper"

describe "customers API" do
  it "finds customers by a name prefix in any case and script, sorted as German readers expect" do
    client = AccountsSpec.client
    ["zulu", "Ärger AG", "Anna", "ärmel", "Österreich", "50% Rabatt", "500 Euro"].each_with_index do |name, index|
      client.post(Billing::Customers::Create.path, json: {name: name, email: "n#{index}@example.org"})
    end
    names = ->(q : String) do
      client.get(Billing::Customers::Search.path, query: {q: q}).json["customers"].as_a.map(&.["name"].as_s)
    end
    names.call("ä").should eq(["Ärger AG", "ärmel"])
    names.call("A").should eq(["Anna"])
    names.call("öst").should eq(["Österreich"])
    names.call("50%").should eq(["50% Rabatt"])
  end

  it "searches through its named query" do
    client = AccountsSpec.client
    client.post(Billing::Customers::Create.path, json: {name: "Anna", email: "anna@example.org"})
    response = client.get(Billing::Customers::Search.path, query: {q: "a"})
    response.json["customers"].as_a.size.should eq(1)
    response.trace.should have_span("Billing::Customers::Queries.search")
  end
end
