require "../spec_helper"

module CoreSpec
  struct InvoiceID < Punch::TypedID
  end

  struct CustomerID < Punch::TypedID
  end
end

describe Punch::TypedID do
  it "parses positive integers into the subtype" do
    id = CoreSpec::InvoiceID.parse(42)
    typeof(id).should eq(CoreSpec::InvoiceID | Punch::Invalid)
    id.as(CoreSpec::InvoiceID).value.should eq(42_i64)
  end

  it "rejects zero, negatives, and values beyond Int64" do
    CoreSpec::InvoiceID.parse(0).should be_invalid("invalid_id")
    CoreSpec::InvoiceID.parse(-1).should be_invalid("invalid_id")
    CoreSpec::InvoiceID.parse(String.new(Bytes[0xFF])).should be_invalid("invalid_id")
    CoreSpec::InvoiceID.parse(UInt64::MAX).should be_invalid("invalid_id")
  end

  it "parses the canonical decimal form only" do
    CoreSpec::InvoiceID.parse("42").as(CoreSpec::InvoiceID).value.should eq(42_i64)
    CoreSpec::InvoiceID.parse("9223372036854775807").should be_a(CoreSpec::InvoiceID)
    ["", "0", "042", "+42", "-42", " 42", "42 ", "4_2", "0x2a", "1e3", "9223372036854775808", "99999999999999999999"].each do |raw|
      CoreSpec::InvoiceID.parse(raw).should be_invalid("invalid_id")
    end
  end

  it "is equal, hashed, and ordered by value within one type" do
    a = CoreSpec::InvoiceID.parse(7).as(CoreSpec::InvoiceID)
    b = CoreSpec::InvoiceID.parse("7").as(CoreSpec::InvoiceID)
    a.should eq(b)
    {a => 1}[b].should eq(1)
    (a < CoreSpec::InvoiceID.parse(8).as(CoreSpec::InvoiceID)).should be_true
    a.to_s.should eq("7")
  end

  it "never equals an ID of another type with the same value" do
    invoice = CoreSpec::InvoiceID.parse(7).as(CoreSpec::InvoiceID)
    customer = CoreSpec::CustomerID.parse(7).as(CoreSpec::CustomerID)
    (invoice == customer).should be_false
  end

  it "reads back from JSON only what parse accepts" do
    CoreSpec::InvoiceID.from_json("7").should eq(CoreSpec::InvoiceID.parse(7))
    Array(Punch::Email).from_json(%(["Ann@Example.org"])).first.to_s.should eq(Punch::Email.parse("Ann@Example.org").to_s)
    expect_raises(JSON::ParseException, /CoreSpec::InvoiceID: invalid_id/) { CoreSpec::InvoiceID.from_json("0") }
    expect_raises(JSON::ParseException, /Punch::Email: /) { Punch::Email.from_json(%("not an address")) }
    expect_raises(JSON::ParseException) { CoreSpec::InvoiceID.from_json(%("7")) }
  end
end
