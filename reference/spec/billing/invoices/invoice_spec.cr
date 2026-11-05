require "../../spec_helper"

private EUR = InvoicingSpec.parse(Punch::Currency, "EUR")

private NOW = Time.utc(2026, 10, 8, 9, 30)

private BILLED_TO = BillingSpec.billed_to(InvoicingSpec.parse(Billing::Customers::ID, 1))

private def draft(lines = [BillingSpec.line]) : Billing::Invoices::Invoice::Draft
  Billing::Invoices::Invoice::Draft.new(
    InvoicingSpec.parse(Billing::Invoices::ID, 1), InvoicingSpec.parse(Billing::Customers::ID, 1),
    EUR, lines, NOW)
end

private def number(sequence = 0_i64) : Billing::Invoices::Number
  Billing::Invoices::Number.next(sequence)
end

describe Billing::Invoices::Invoice do
  it "totals its lines in minor units" do
    invoice = draft([BillingSpec.line(quantity: 3, unit_price: 12_500), BillingSpec.line(quantity: 1, unit_price: -2_000)])
    invoice.lines.map(&.total.value).should eq([37_500, -2_000])
    invoice.total.value.should eq(35_500)
    draft([] of Billing::Invoices::Invoice::Line).total.should eq(Punch::Money.zero)
  end

  it "keeps the largest invoice inside Money's range" do
    largest = BillingSpec.line(quantity: Billing::Invoices::Quantity::MAX, unit_price: Billing::Invoices::Invoice::MAX_UNIT_PRICE)
    draft(Array.new(Billing::Invoices::Invoice::MAX_LINES, largest)).total.value.should eq(1_000_000_000_000_000)
  end

  it "sends a draft: numbered, sent now, due after the payment term" do
    sent = draft.send(number(41), NOW, BILLED_TO).as(Billing::Invoices::Invoice::Sent)
    sent.number.value.should eq("INV-000042")
    sent.sent_at.should eq(NOW)
    sent.due_at.should eq(NOW + 14.days)
    sent.lines.should eq(draft.lines)
    sent.status.should eq(Billing::Invoices::Invoice::Status::Sent)
  end

  it "does not send a draft without lines" do
    draft([] of Billing::Invoices::Invoice::Line).send(number, NOW, BILLED_TO).should be_a(Billing::Invoices::Invoice::NoLines)
  end

  it "shares the overdue rule with list rows, where a draft has no due date" do
    sent = draft.send(number, NOW, BILLED_TO).as(Billing::Invoices::Invoice::Sent)
    paid = sent.pay(sent.total, EUR, NOW + 20.days, InvoicingSpec.parse(Punch::NonEmptyString, "pay_1")).as(Billing::Invoices::Invoice::Paid)
    row = ->(due_at : Time?, paid_at : Time?) do
      Billing::Invoices::Queries::Page::Row.new(id: sent.id, status: "sent", number: nil, currency: EUR, customer_id: sent.customer_id,
        customer_name: InvoicingSpec.parse(Punch::NonEmptyString, "Ada"), total: 0_i64, sent_at: nil, due_at: due_at, paid_at: paid_at)
    end
    [NOW + 14.days, NOW + 14.days + 1.second, NOW + 30.days].each do |now|
      row.call(sent.due_at, nil).overdue?(now).should eq(sent.overdue?(now))
      row.call(paid.due_at, paid.paid_at).overdue?(now).should eq(paid.overdue?(now))
    end
    row.call(nil, nil).overdue?(NOW + 1000.days).should be_false
  end

  it "is paid by its total in its currency, and then never overdue" do
    sent = draft.send(number, NOW, BILLED_TO).as(Billing::Invoices::Invoice::Sent)
    reference = InvoicingSpec.parse(Punch::NonEmptyString, "pay_1")
    paid = sent.pay(sent.total, EUR, NOW + 20.days, reference).as(Billing::Invoices::Invoice::Paid)
    {paid.status, paid.number, paid.due_at, paid.paid_at, paid.payment_reference}.should eq({Billing::Invoices::Invoice::Status::Paid, sent.number, sent.due_at, NOW + 20.days, reference})
    paid.overdue?(NOW + 100.days).should be_false

    short = sent.pay(InvoicingSpec.parse(Punch::Money, sent.total.value - 1), EUR, NOW, reference)
    short.should eq(Billing::Invoices::Invoice::WrongAmount.new(sent.total, EUR))
    sent.pay(sent.total, InvoicingSpec.parse(Punch::Currency, "CHF"), NOW, reference).should be_a(Billing::Invoices::Invoice::WrongAmount)
  end

  it "is overdue only after its due date" do
    sent = draft.send(number, NOW, BILLED_TO).as(Billing::Invoices::Invoice::Sent)
    sent.overdue?(NOW + 14.days).should be_false
    sent.overdue?(NOW + 14.days + 1.second).should be_true
  end

  it "revises a draft into a new draft" do
    usd = InvoicingSpec.parse(Punch::Currency, "USD")
    revised = draft.revise(currency: usd)
    revised.currency.should eq(usd)
    revised.lines.should eq(draft.lines)
    draft.revise(lines: [] of Billing::Invoices::Invoice::Line).lines.should be_empty
  end
end
