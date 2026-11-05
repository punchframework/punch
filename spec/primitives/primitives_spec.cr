require "../spec_helper"

module CoreSpec
  # A primitive defined the way an application defines one.
  struct InvoiceNumber
    include Punch::Primitive(String)

    def self.parse(raw : String) : self | Punch::Invalid
      raw.matches?(/\AINV-\d{6}\z/) ? new(raw) : Punch::Invalid.new("invalid_invoice_number")
    end
  end
end

describe Punch::Primitive do
  it "lets an application define its own primitive" do
    number = CoreSpec::InvoiceNumber.parse("INV-000042")
    typeof(number).should eq(CoreSpec::InvoiceNumber | Punch::Invalid)
    number.as(CoreSpec::InvoiceNumber).value.should eq("INV-000042")
    number.to_s.should eq("INV-000042")
    CoreSpec::InvoiceNumber.parse("42").should be_invalid("invalid_invoice_number")
  end

  it "compares and hashes by value" do
    a = CoreSpec::InvoiceNumber.parse("INV-000001")
    a.should eq(CoreSpec::InvoiceNumber.parse("INV-000001"))
    Set{a, CoreSpec::InvoiceNumber.parse("INV-000001")}.size.should eq(1)
  end
end

describe Punch::NonEmptyString do
  it "strips surrounding whitespace" do
    Punch::NonEmptyString.parse("  Ann Lee \n").as(Punch::NonEmptyString).value.should eq("Ann Lee")
  end

  it "keeps inner line breaks and tabs" do
    Punch::NonEmptyString.parse("a\n\tb").as(Punch::NonEmptyString).value.should eq("a\n\tb")
  end

  it "rejects blank text" do
    ["", " ", "\n\t "].each { |raw| Punch::NonEmptyString.parse(raw).should be_invalid("blank") }
  end

  it "normalizes to NFC, so one text typed two ways is one value" do
    composed = Punch::NonEmptyString.parse("Café")
    decomposed = Punch::NonEmptyString.parse("Café")
    decomposed.should eq(composed)
    decomposed.as(Punch::NonEmptyString).value.size.should eq(4)
  end

  it "rejects control characters and invalid UTF-8" do
    Punch::NonEmptyString.parse("a\u0000b").should be_invalid("invalid_characters")
    Punch::NonEmptyString.parse("a\u001Bb").should be_invalid("invalid_characters")
    Punch::NonEmptyString.parse("a\u007Fb").should be_invalid("invalid_characters")
    Punch::NonEmptyString.parse(String.new(Bytes[0x61, 0xFF])).should be_invalid("invalid_encoding")
  end
end

describe Punch::Slug do
  it "accepts lowercase groups joined by single hyphens" do
    %w[a 2026 annual-report-2026 a-b-c].each do |raw|
      Punch::Slug.parse(raw).as(Punch::Slug).value.should eq(raw)
    end
  end

  it "checks instead of converting" do
    ["Annual", "annual report", "-a", "a-", "a--b", "a_b", "ärger", "a/b", "a.b"].each do |raw|
      Punch::Slug.parse(raw).should be_invalid("invalid_slug")
    end
  end

  it "rejects empty and overlong slugs" do
    Punch::Slug.parse("").should be_invalid("blank")
    Punch::Slug.parse("a" * 100).should be_a(Punch::Slug)
    Punch::Slug.parse("a" * 101).should be_invalid("too_long", max: 100)
  end
end

describe Punch::Email do
  it "lowercases and trims" do
    email = Punch::Email.parse("  Ann.Lee@Example.ORG ").as(Punch::Email)
    email.value.should eq("ann.lee@example.org")
    email.domain.should eq("example.org")
  end

  it "accepts common and international forms" do
    ["a@b.co", "first.last+tag@sub.example.com", "o'brien@example.ie", "x_y-z@ex-ample.org",
     "jörg@müller.de", "用户@例子.广告", "a@xn--mller-kva.de"].each do |raw|
      Punch::Email.parse(raw).should be_a(Punch::Email)
    end
  end

  it "rejects malformed addresses" do
    ["plain", "@example.org", "ann@", "ann@localhost", "ann@example", "ann@@example.org",
     "an n@example.org", ".ann@example.org", "ann.@example.org", "a..b@example.org",
     "\"ann\"@example.org", "ann@[192.0.2.1]", "ann@192.0.2.1", "ann@-example.org",
     "ann@example-.org", "ann@exa_mple.org", "ann@example..org", "ann@.example.org",
     "<ann@example.org>", "ann@example.org,bob@example.org"].each do |raw|
      Punch::Email.parse(raw).should be_invalid("invalid_email")
    end
  end

  it "enforces the length limits" do
    Punch::Email.parse("").should be_invalid("blank")
    Punch::Email.parse("#{"a" * 64}@example.org").should be_a(Punch::Email)
    Punch::Email.parse("#{"a" * 65}@example.org").should be_invalid("invalid_email")
    Punch::Email.parse("a@#{"b" * 63}.org").should be_a(Punch::Email)
    Punch::Email.parse("a@#{"b" * 64}.org").should be_invalid("invalid_email")
    long = "a@#{(["b" * 60] * 5).join('.')}.org"
    Punch::Email.parse(long).should be_invalid("too_long", max: 254)
  end

  it "rejects header injection" do
    Punch::Email.parse("ann@example.org\r\nBcc: eve@example.org").should be_invalid("invalid_email")
    Punch::Email.parse("ann@example.org\u0000").should be_invalid("invalid_characters")
  end

  it "is one value however the address was cased" do
    Punch::Email.parse("Ann@Example.org").should eq(Punch::Email.parse("ann@example.org"))
  end
end

describe Punch::Money do
  it "holds an amount in minor units within the integers JavaScript reads exactly" do
    Punch::Money.parse(1250).as(Punch::Money).value.should eq(1250)
    Punch::Money.parse(-1250).should be_a(Punch::Money)
    Punch::Money.parse(Punch::Money::MAX).should be_a(Punch::Money)
    Punch::Money.parse(-Punch::Money::MAX).should be_a(Punch::Money)
    Punch::Money.parse(Punch::Money::MAX + 1).should be_invalid("out_of_range", min: -Punch::Money::MAX, max: Punch::Money::MAX)
    Punch::Money.parse(Int64::MIN).should be_invalid("out_of_range", min: -Punch::Money::MAX, max: Punch::Money::MAX)
  end

  it "adds, subtracts, multiplies, and compares" do
    a = Punch::Money.parse(1250).as(Punch::Money)
    b = Punch::Money.parse(250).as(Punch::Money)
    (a + b).value.should eq(1500)
    (a - b * 6).value.should eq(-250)
    (-a).value.should eq(-1250)
    (a > b).should be_true
    Punch::Money.zero.zero?.should be_true
    (b - a).negative?.should be_true
  end

  it "raises beyond the range instead of losing precision" do
    max = Punch::Money.parse(Punch::Money::MAX).as(Punch::Money)
    expect_raises(OverflowError) { max + Punch::Money.parse(1).as(Punch::Money) }
    expect_raises(OverflowError) { max * 2 }
    expect_raises(OverflowError) { max * Int64::MAX }
  end

  it "serializes as a JSON integer" do
    Punch::Money.parse(1250).as(Punch::Money).to_json.should eq("1250")
  end
end

describe Punch::Currency do
  it "accepts ISO 4217 codes by form" do
    %w[EUR USD JPY CHF].each { |raw| Punch::Currency.parse(raw).as(Punch::Currency).value.should eq(raw) }
    ["eur", "EU", "EURO", "E1R", " EUR", ""].each { |raw| Punch::Currency.parse(raw).should be_invalid("invalid_currency") }
  end
end

describe Punch::PageSize do
  it "accepts 1 to 100 and says the bounds when refusing" do
    {1, 50, 100}.each { |size| Punch::PageSize.parse(size).as(Punch::PageSize).to_i.should eq(size) }
    {0, 101, -5}.each { |size| Punch::PageSize.parse(size).should be_invalid("out_of_range") }
  end

  it "builds a size in code, and raises outside the bounds" do
    Punch::PageSize.of(20).value.should eq(20)
    expect_raises(ArgumentError, "a page size is 1 to 100, not 0") { Punch::PageSize.of(0) }
  end

  it "has bounds in its JSON schema" do
    Punch::PageSize.json_schema.should eq({minimum: 1, maximum: 100})
  end
end
