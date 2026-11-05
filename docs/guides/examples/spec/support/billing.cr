module BillingSpec
  # An invoice of *email* due at *due_at*, numbered in order.
  def self.invoice(due_at : Time, email = "ada@example.org", paid_at : Time? = nil, reminded_at : Time? = nil) : Billing::Invoices::Record
    @@numbers += 1
    Punch::Spec.db.write do |db|
      Punch.cannot_violate(Billing::Invoices::Table.insert(db, number: "INV-#{@@numbers.to_s.rjust(6, '0')}", customer_email: ExamplesSpec.parse(Punch::Email, email),
        due_at: due_at, paid_at: paid_at, reminded_at: reminded_at))
    end
  end

  @@numbers = 0
end
