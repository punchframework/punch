require "../../spec_helper"

describe Billing::Products::Create do
  it "keeps a product's prices in one document, and refuses more currencies than the bound" do
    client = AccountsSpec.client
    prices = [{currency: "EUR", amount: 12_000}, {currency: "CHF", amount: 11_500}]
    created = client.post(Billing::Products::Create.path, json: {name: "Consulting", unit: "hour", prices: prices})
    created.status.should eq(HTTP::Status::CREATED)
    created.json["pricing"].should eq(JSON.parse(%({"unit": "hour", "prices": {"EUR": 12000, "CHF": 11500}})))

    four = prices + [{currency: "USD", amount: 13_000}, {currency: "GBP", amount: 10_500}]
    refused = client.post(Billing::Products::Create.path, json: {name: "Workshop", unit: "day", prices: four})
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.json["errors"][0]["path"].should eq(JSON.parse(%(["prices"])))
    refused.json["errors"][0]["code"].should eq("too_many")
  end

  it "builds a pricing only within its bound" do
    eur = ExamplesSpec.parse(Punch::Currency, "EUR")
    hour = ExamplesSpec.parse(Punch::NonEmptyString, "hour")
    pricing = Billing::Products::Pricing.build(unit: hour, prices: {eur => ExamplesSpec.parse(Punch::Money, 12_000_i64)}).as(Billing::Products::Pricing)
    pricing.prices[eur].should eq(ExamplesSpec.parse(Punch::Money, 12_000_i64))

    many = %w[EUR CHF USD GBP].to_h { |code| {ExamplesSpec.parse(Punch::Currency, code), ExamplesSpec.parse(Punch::Money, 100_i64)} }
    Billing::Products::Pricing.build(unit: hour, prices: many).should be_invalid("too_many", max: 3, field: "prices")
  end
end
