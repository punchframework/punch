require "../../spec_helper"

# "Save, then load, returns the same model" (lib/punch/docs/models.md): a field the store
# forgets to map shows up here.

private EUR = InvoicingSpec.parse(Punch::Currency, "EUR")

describe Billing::Invoices::Store do
  it "loads what it created and saved, in every state" do
    Punch::Spec.db.write do |db|
      customer = BillingSpec.customer(db)
      lines = [BillingSpec.line("Consulting", 3, 12_500), BillingSpec.line("Travel", 1, 4_990)]
      draft = Billing::Invoices::Store.create(db, organization_id: customer.organization_id, customer_id: customer.id, currency: EUR, lines: lines, at: Time.utc)
      Billing::Invoices::Store.load(db, draft.id).should eq(draft)
      revised = draft.revise(currency: InvoicingSpec.parse(Punch::Currency, "CHF"), lines: lines.reverse)
      sent = revised.send(Billing::Invoices::Store.next_number(db), Time.utc, BillingSpec.billed_to(customer.id)).as(Billing::Invoices::Invoice::Sent)
      paid = sent.pay(sent.total, sent.currency, Time.utc, InvoicingSpec.parse(Punch::NonEmptyString, "pay_1")).as(Billing::Invoices::Invoice::Paid)

      Punch::Spec.round_trip(revised, sent, paid, covering: Billing::Invoices::Invoice::Any) do |invoice|
        Billing::Invoices::Store.save(db, invoice)
        Billing::Invoices::Store.load(db, invoice.id)
      end
      Billing::Invoices::Store.next_number(db).value.should eq("INV-000002")
    end
  end

  it "deletes a draft with its lines" do
    Punch::Spec.db.write do |db|
      customer = BillingSpec.customer(db)
      draft = Billing::Invoices::Store.create(db, organization_id: customer.organization_id, customer_id: customer.id, currency: EUR, lines: [BillingSpec.line], at: Time.utc)
      Billing::Invoices::Store.delete(db, draft)
      Billing::Invoices::Store.load(db, draft.id).should be_nil
      Billing::Invoices::Queries.lines(db, invoice_id: draft.id).should be_empty
    end
  end

  it "refuses a row whose status names no state" do
    Punch::Spec.db.write do |db|
      customer = BillingSpec.customer(db)
      draft = Billing::Invoices::Store.create(db, organization_id: customer.organization_id, customer_id: customer.id, currency: EUR, lines: [] of Billing::Invoices::Invoice::Line, at: Time.utc)
      # Paid is a sent invoice with a payment, not a status of its own.
      expect_raises(Punch::Database::ConstraintError) { db.exec("UPDATE invoices SET status = 'paid'") }
      expect_raises(Punch::Database::RowError, "invoices.status in row #{draft.id.value} does not parse") do
        Billing::Invoices::Store.status("paid", draft.id, nil)
      end
    end
  end
end
