require "../../spec_helper"

private def add(email : String, method : Billing::PaymentMethods::Method) : Billing::PaymentMethods::Record
  Punch::Spec.db.write do |db|
    Billing::PaymentMethods::Table.insert(db, customer_email: ExamplesSpec.parse(Punch::Email, email), method: method)
  end
end

private def card : Billing::PaymentMethods::Card
  Billing::PaymentMethods::Card.build(brand: ExamplesSpec.parse(Punch::NonEmptyString, "Visa"),
    last4: ExamplesSpec.parse(Punch::NonEmptyString, "4242")).as(Billing::PaymentMethods::Card)
end

private def transfer : Billing::PaymentMethods::Transfer
  Billing::PaymentMethods::Transfer.build(iban: ExamplesSpec.parse(Punch::NonEmptyString, "DE89370400440532013000"),
    reference: nil).as(Billing::PaymentMethods::Transfer)
end

describe Billing::PaymentMethods do
  it "reads each method back as its own type, told apart by its kind" do
    add("ada@example.org", card)
    add("ada@example.org", transfer)
    methods = Punch::Spec.db.read { |db| Billing::PaymentMethods::Queries.of_customer(db, customer_email: ExamplesSpec.parse(Punch::Email, "ada@example.org")) }
    endings = methods.map do |row|
      case method = row.method
      in Billing::PaymentMethods::Card     then "#{method.brand} ending #{method.last4}"
      in Billing::PaymentMethods::Transfer then "transfer from …#{method.iban.value[-4..]}"
      end
    end
    endings.should eq(["Visa ending 4242", "transfer from …3000"])
  end

  it "stores the kind in the document, and answers with it" do
    add("ada@example.org", card)
    Punch::Spec.db.read { |db| db.query_one?("SELECT method FROM payment_methods", &.read(String)) }
      .should eq(%({"kind":"card","brand":"Visa","last4":"4242"}))
    listed = AccountsSpec.client.get(Billing::PaymentMethods::Index.path, query: {customer_email: "ada@example.org"})
    listed.json["methods"].should eq(JSON.parse(%([{"kind": "card", "brand": "Visa", "last4": "4242"}])))
  end

  it "types a path into the document from the composite" do
    add("ada@example.org", card)
    add("ada@example.org", transfer)
    brands = Punch::Spec.db.read { |db| Billing::PaymentMethods::Queries.card_brands(db, customer_email: ExamplesSpec.parse(Punch::Email, "ada@example.org")) }
    brands.map(&.brand).should eq([ExamplesSpec.parse(Punch::NonEmptyString, "Visa")])
  end
end
