require "../../spec_helper"

private def stored(id : Billing::Customers::ID) : {Bytes, Bytes}
  Punch::Spec.db.read { |db| db.query_one?("SELECT email_encrypted, email_index FROM customers WHERE id = ?", id.value) { |row| {row.read(Bytes), row.read(Bytes)} } } || raise "no customer #{id}"
end

# The customer email is stored encrypted, converted from a plaintext column
# in three releases (db/migrations/*_encrypt_customer_emails.sql and the two
# after it), and kept unique through its blind index.
describe "a customer's email" do
  it "is stored encrypted, with its blind index, and unique in an organization in any case" do
    client = AccountsSpec.client
    raw = client.post(Billing::Customers::Create.path, json: {name: "Ada", email: "Ada@example.org"}).json["customer"]["id"].as_s
    id = InvoicingSpec.parse(Billing::Customers::ID, raw)
    encrypted, index = stored(id)
    encrypted.should be_encrypted_for("customers", "email_encrypted")
    String.new(encrypted).should_not contain("example.org")
    index.should eq(Punch::Stored.blind_index(InvoicingSpec.parse(Punch::Email, "ada@example.org"), "customers", "email_index"))
    Punch::Spec.db.read { |db| db.query_all("SELECT name FROM pragma_table_info('customers')", &.read(String)) }.should_not contain("email")
    client.post(Billing::Customers::Create.path, json: {name: "Ada", email: "ADA@example.org"}).json["errors"][0]["path"].should eq(JSON.parse(%(["email"])))
    AccountsSpec.client.post(Billing::Customers::Create.path, json: {name: "Ada", email: "ada@example.org"}).status.should eq(HTTP::Status::CREATED)
  end
end
