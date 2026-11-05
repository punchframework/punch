require "../../spec_helper"

private def create(client, email = "ada@example.org", company_name : String? = nil)
  client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email, company_name: company_name})
end

describe "customers API" do
  it "pages through customers in creation order" do
    client = AccountsSpec.client
    5.times { |index| create(client, "c#{index}@example.org") }
    first = client.get(Billing::Customers::Index.path, query: {limit: 2}).json
    first["customers"].as_a.map(&.["email"].as_s).should eq(%w[c0@example.org c1@example.org])
    after = first["next_after"].as_s
    rest = client.get(Billing::Customers::Index.path, query: {after: after, limit: 10}).json
    rest["customers"].as_a.size.should eq(3)
    rest["next_after"]?.should be_nil
    client.get(Billing::Customers::Index.path, query: {limit: 101}).json["errors"][0]["code"].should eq("out_of_range")
  end

  it "pages through customers by name in German order, across equal names" do
    client = AccountsSpec.client
    %w[Zander Müller Ärger Abel Müller Öhler Mueller].each_with_index do |name, index|
      client.post(Billing::Customers::Create.path, json: {name: name, email: "p#{index}@example.org"})
    end
    seen = [] of String
    after = nil
    pages = 0
    loop do
      page = client.get(Billing::Customers::Index.path, query: {order: "name", limit: 3, after: after}).json
      seen.concat(page["customers"].as_a.map(&.["email"].as_s))
      pages += 1
      after = page["next_after"]?.try(&.as_s) || break
    end
    pages.should eq(3)
    # The two Müllers in the order they were created, as the ID breaks the tie.
    seen.should eq(%w[p3 p2 p6 p1 p4 p5 p0].map { |local| "#{local}@example.org" })
    backwards = client.get(Billing::Customers::Index.path, query: {order: "name", direction: "desc", limit: 3}).json
    backwards["customers"].as_a.map(&.["email"].as_s).should eq(%w[p0 p5 p4].map { |local| "#{local}@example.org" })
    client.get(Billing::Customers::Index.path, query: {after: backwards["next_after"].as_s, limit: 3}).json["customers"].as_a.map(&.["email"].as_s).should eq(
      %w[p1 p6 p2].map { |local| "#{local}@example.org" })
    client.get(Billing::Customers::Index.path, query: {after: "nonsense"}).json["errors"][0]["code"].should eq("invalid_cursor")
  end
end
