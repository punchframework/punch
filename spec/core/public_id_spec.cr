require "../spec_helper"

module PublicIDSpec
  struct InvoiceID < Punch::TypedID
    public_id "inv"
  end

  struct CustomerID < Punch::TypedID
    public_id "cus"
  end

  struct LineID < Punch::TypedID
  end

  record Payload, invoice_id : InvoiceID, line_id : LineID?, invoices : Array(InvoiceID) do
    include JSON::Serializable
  end

  struct Show
    include Punch::Input

    @[Punch::PathParam]
    getter invoice_id : InvoiceID

    getter customer_id : CustomerID?
    getter line_id : LineID?
  end
end

private def with_key(key : Bytes, &)
  previous = Punch::Crypto::PublicIDs.root?
  Punch::Crypto::PublicIDs.root = key
  yield
ensure
  previous.try { |root| Punch::Crypto::PublicIDs.root = root }
end

private def invoice(rowid : Int64) : PublicIDSpec::InvoiceID
  PublicIDSpec::InvoiceID.parse(rowid).as(PublicIDSpec::InvoiceID)
end

private KEY = Punch::Crypto.random_key

describe "Punch::TypedID.public_id" do
  it "writes the prefix and 11 characters of base58, and reads them back" do
    with_key(KEY) do
      [1_i64, 2_i64, 42_i64, 1_000_000_i64, Int64::MAX].each do |rowid|
        text = invoice(rowid).to_s
        text.should match(/\Ainv_[1-9A-HJ-NP-Za-km-z]{11}\z/)
        PublicIDSpec::InvoiceID.parse(text).as(PublicIDSpec::InvoiceID).value.should eq(rowid)
      end
    end
  end

  it "neither counts nor orders: neighbouring rowids give unrelated texts" do
    with_key(KEY) do
      texts = (1_i64..1000_i64).map { |rowid| invoice(rowid).to_s }
      texts.uniq.size.should eq(1000)
      texts.sort.should_not eq(texts)
      texts.map(&.[4]).uniq!.size.should be > 40
    end
  end

  it "gives each type its own texts" do
    with_key(KEY) do
      customer = PublicIDSpec::CustomerID.parse(42).as(PublicIDSpec::CustomerID)
      customer.to_s.lchop("cus_").should_not eq(invoice(42).to_s.lchop("inv_"))
      PublicIDSpec::InvoiceID.parse(customer.to_s.sub("cus_", "inv_")).should_not eq(invoice(42))
    end
  end

  it "accepts only its own public form from outside" do
    with_key(KEY) do
      text = invoice(42).to_s
      ["42", "", text.lchop("inv_"), "cus_#{text.lchop("inv_")}", "#{text}1", text[0..-2], text.sub(/.\z/, "0"), "inv_zzzzzzzzzzz"].each do |raw|
        PublicIDSpec::InvoiceID.parse(raw).should be_invalid("invalid_id")
      end
    end
  end

  it "changes every text under another key" do
    text = with_key(KEY) { invoice(42).to_s }
    with_key(KEY.dup) { invoice(42).to_s.should eq(text) }
    with_key(Punch::Crypto.random_key) { invoice(42).to_s.should_not eq(text) }
  end

  it "travels as text in paths, query strings, JSON, schemas and DOM IDs" do
    with_key(KEY) do
      id = invoice(42)
      customer = PublicIDSpec::CustomerID.parse(7).as(PublicIDSpec::CustomerID)
      input = PublicIDSpec::Show.from_json(%({"customer_id": "#{customer}", "line_id": 3}), {"invoice_id" => id.to_s}).as(PublicIDSpec::Show)
      input.invoice_id.should eq(id)
      input.customer_id.should eq(customer)
      PublicIDSpec::Show.from_json(%({"customer_id": 7}), {"invoice_id" => id.to_s}).should be_a(Punch::Rejection)
      PublicIDSpec::Show.from_json("{}", {"invoice_id" => "42"}).should be_a(Punch::Rejection)

      id.to_json.should eq(%("#{id}"))
      PublicIDSpec::InvoiceID.from_json(id.to_json).should eq(id)
      expect_raises(JSON::ParseException, /expected_string/) { PublicIDSpec::InvoiceID.from_json("42") }
      schema = Punch::JSONSchema.of(PublicIDSpec::InvoiceID)
      {schema["type"], schema["pattern"]}.should eq({"string", "^inv_[1-9A-HJ-NP-Za-km-z]{11}$"})
      Punch.dom_id(id).should eq(id.to_s)
      Punch.dom_id(id, "lines").should eq("lines_#{id}")
    end
  end
end

describe "Punch::Stored.json" do
  it "keeps the rowid of a public ID in what the app stores for itself" do
    with_key(KEY) do
      payload = PublicIDSpec::Payload.new(invoice(42), PublicIDSpec::LineID.parse(3).as(PublicIDSpec::LineID), [invoice(7)])
      stored = Punch::Stored.json(payload)
      stored.should eq(%({"invoice_id":42,"line_id":3,"invoices":[7]}))
      Punch::Stored.from_json(PublicIDSpec::Payload, stored).invoice_id.should eq(invoice(42))
      payload.to_json.should eq(%({"invoice_id":"#{invoice(42)}","line_id":3,"invoices":["#{invoice(7)}"]}))
    end
  end

  it "reads only the rowid back, so stored JSON never depends on the key" do
    with_key(KEY) do
      expect_raises(JSON::ParseException, /expected_integer/) do
        Punch::Stored.from_json(PublicIDSpec::Payload, %({"invoice_id":"#{invoice(42)}","invoices":[]}))
      end
    end
    Punch::Stored.from_json(PublicIDSpec::Payload, %({"invoice_id":42,"invoices":[]})).invoice_id.value.should eq(42)
  end

  it "describes stored payloads with the rowid's schema" do
    registry = Punch::JSONSchema::Registry.new(payloads: true)
    registry.schema(PublicIDSpec::InvoiceID).should eq(JSON.parse(%({"type":"integer","format":"int64","minimum":1})))
  end
end

describe "Punch::Paged::Cursor over public IDs" do
  layouts = {"" => [Punch::Paged::Cursor::Kind::Integer]}

  it "is sealed when a sort value is a public ID, and reads back only sealed" do
    with_key(KEY) do
      Punch::Paged::Cursor.sealed?(PublicIDSpec::InvoiceID, String).should be_true
      Punch::Paged::Cursor.sealed?(PublicIDSpec::LineID, String).should be_false
      values = [42_i64] of Punch::Database::Value
      sealed = Punch::Paged::Cursor.encode(nil, values, sealed: true)
      plain = Punch::Paged::Cursor.encode(nil, values)
      Base64.decode_string(plain).should eq("[42]")
      sealed.should_not eq(Punch::Paged::Cursor.encode(nil, values, sealed: true))
      Punch::Paged::Cursor.decode(sealed, layouts, sealed: true).should eq({"", Punch::Database::Direction::Asc, values})
      Punch::Paged::Cursor.decode(plain, layouts, sealed: true).should be_nil
      Punch::Paged::Cursor.decode(sealed.sub(20, sealed[20] == 'A' ? 'B' : 'A'), layouts, sealed: true).should be_nil
      Punch::Paged::Cursor.decode(sealed, layouts).should be_nil
    end
  end
end

describe Punch::Crypto::SipHash do
  key = Bytes.new(16, &.to_u8)
  k0 = IO::ByteFormat::LittleEndian.decode(UInt64, key[0, 8])
  k1 = IO::ByteFormat::LittleEndian.decode(UInt64, key[8, 8])

  it "gives the reference vectors of the SipHash paper" do
    {0 => 0x726fdb47dd0e0e31_u64, 8 => 0x93f5f5799a932462_u64, 15 => 0xa129ca6149be45e5_u64}.each do |size, expected|
      Punch::Crypto::SipHash.digest(k0, k1, Bytes.new(size, &.to_u8)).should eq(expected)
    end
  end

  it "hashes one word as its 8 little-endian bytes" do
    [0_u64, 1_u64, 0x0706050403020100_u64, UInt64::MAX].each do |word|
      bytes = Bytes.new(8)
      IO::ByteFormat::LittleEndian.encode(word, bytes)
      Punch::Crypto::SipHash.word(k0, k1, word).should eq(Punch::Crypto::SipHash.digest(k0, k1, bytes))
    end
  end
end
