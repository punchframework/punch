require "../../spec_helper"

# The invoice list's filter as a value (lib/punch/docs/queries.md): built in code and run
# against the query, without the operation or a request.
private EUR = InvoicingSpec.parse(Punch::Currency, "EUR")

describe Billing::Invoices::Queries::Page::Filter do
  it "narrows the list to one state, a paid invoice being a sent one with a payment" do
    organization, ids = Punch::Spec.db.write do |db|
      customer = BillingSpec.customer(db)
      drafts = Array.new(3) do
        Billing::Invoices::Store.create(db, organization_id: customer.organization_id, customer_id: customer.id, currency: EUR,
          lines: [BillingSpec.line], at: Time.utc)
      end
      sent = drafts.first(2).map do |draft|
        draft.send(Billing::Invoices::Store.next_number(db), Time.utc, BillingSpec.billed_to(customer.id)).as(Billing::Invoices::Invoice::Sent).tap { |invoice| Billing::Invoices::Store.save(db, invoice) }
      end
      paid = sent[0].pay(sent[0].total, EUR, Time.utc, InvoicingSpec.parse(Punch::NonEmptyString, "pay_1")).as(Billing::Invoices::Invoice::Paid)
      Billing::Invoices::Store.save(db, paid)
      {customer.organization_id, drafts.map(&.id)}
    end

    listed = ->(filter : Billing::Invoices::Queries::Page::Filter) do
      Punch::Spec.db.read { |db| Billing::Invoices::Queries.page(db, organization_id: organization, filter: filter, limit: 10).map(&.id) }
    end
    listed.call(Billing::Invoices::Queries::Page::Filter.new).should eq(ids)
    listed.call(Billing::Invoices::Queries::Page::Filter.new(status: :draft)).should eq([ids[2]])
    listed.call(Billing::Invoices::Queries::Page::Filter.new(status: :sent)).should eq([ids[1]])
    listed.call(Billing::Invoices::Queries::Page::Filter.new(status: :paid)).should eq([ids[0]])

    # One invoice as the list shows it: the same clauses, by key.
    by_key = ->(id : Billing::Invoices::ID, filter : Billing::Invoices::Queries::Page::Filter) do
      Punch::Spec.db.read { |db| Billing::Invoices::Queries.page_by_key(db, key: id, organization_id: organization, filter: filter).try(&.id) }
    end
    by_key.call(ids[0], Billing::Invoices::Queries::Page::Filter.new(status: :paid)).should eq(ids[0])
    by_key.call(ids[0], Billing::Invoices::Queries::Page::Filter.new(status: :draft)).should be_nil
    by_key.call(ids[2], Billing::Invoices::Queries::Page::Filter.new(status: :draft)).should eq(ids[2])
  end
end
