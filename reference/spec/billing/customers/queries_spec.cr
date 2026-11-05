require "../../spec_helper"

describe "customers API" do
  it "continues a page by name through the collated index" do
    sql = [Billing::Customers::Queries::Page::SQL_1, Billing::Customers::Queries::Page::AFTER_NAME,
           Billing::Customers::Queries::Page::ORDER_NAME, "LIMIT ?"].join('\n')
    Punch::Spec.db.read do |db|
      plan = db.query_all("EXPLAIN QUERY PLAN #{sql}", 1_i64, "Müller", 2_i64, 51_i64) do |row|
        3.times { row.read(Int64) }
        row.read(String)
      end
      # SQLite seeks by the name and checks the ID on the rows of an equal
      # name; no sort step either way.
      plan.join(" | ").should contain("USING INDEX customers_by_name (organization_id=? AND name>?)")
      plan.join(" | ").should_not contain("TEMP B-TREE")
    end
  end

  # A list of names with umlauts sorts correctly through an
  # index, not by sorting the result.
  it "reads names in German order from the collated index" do
    Punch::Spec.db.write do |db|
      organization = AccountsSpec.organization(db, AccountsSpec.user(db).id)
      %w[Zander Ärger Abel Öhler Ober Müller Mueller].each_with_index do |name, index|
        Punch.cannot_violate(Billing::Customers::Table.insert(db, organization_id: organization, name: InvoicingSpec.parse(Punch::NonEmptyString, name),
          email_encrypted: Punch::Secret.new(InvoicingSpec.parse(Punch::Email, "x#{index}@example.org")), created_at: Time.utc))
      end
      db.query_all("SELECT name FROM customers ORDER BY name", &.read(String)).should eq(%w[Abel Ärger Mueller Müller Ober Öhler Zander])
      plan = db.query_all("EXPLAIN QUERY PLAN #{Billing::Customers::Queries::Search::SQL}", organization.value, "", 20_i64) do |row|
        3.times { row.read(Int64) }
        row.read(String)
      end
      plan.join(" | ").should contain("customers_by_name")
      plan.join(" | ").should_not contain("TEMP B-TREE")
    end
  end
end
