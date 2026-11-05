require "../spec_helper"

describe Punch::Invalid do
  it "carries a code and params, never a sentence" do
    invalid = Punch::Invalid.new("too_long", max: 64, unit: :characters)
    invalid.code.should eq("too_long")
    invalid.params.should eq({"max" => 64_i64, "unit" => "characters"})
  end

  it "refuses codes that are not snake_case, as a bug" do
    expect_raises(ArgumentError) { Punch::Invalid.new("Too long") }
    expect_raises(ArgumentError) { Punch::Invalid.new("") }
  end

  it "compares by code and params" do
    Punch::Invalid.new("blank").should eq(Punch::Invalid.new("blank"))
    Punch::Invalid.new("too_long", max: 3).should_not eq(Punch::Invalid.new("too_long", max: 4))
  end
end

describe Punch::Rejection do
  it "needs at least one error" do
    expect_raises(ArgumentError) { Punch::Rejection.new([] of Punch::Rejection::FieldError) }
  end

  it "finds errors by path" do
    rejection = Punch::Rejection.new([
      Punch::Rejection::FieldError.new(Punch::Rejection::Path{"email"}, Punch::Invalid.new("blank")),
      Punch::Rejection::FieldError.new(Punch::Rejection::Path{"lines", 1, "amount"}, Punch::Invalid.new("negative")),
    ])
    rejection.at("email").map(&.code).should eq(["blank"])
    rejection.at("lines", 1, "amount").map(&.code).should eq(["negative"])
    rejection.at("name").should be_empty
  end
end

describe Punch::Rejection::Collector do
  it "returns parsed values and the block's result when nothing failed" do
    errors = Punch::Rejection::Collector.new
    email = errors.check("email", Punch::Email.parse("ann@example.org"))
    typeof(email).should eq(Punch::Email?)
    errors.result { email.try(&.value) }.should eq("ann@example.org")
  end

  it "collects every error, not just the first" do
    errors = Punch::Rejection::Collector.new
    errors.check("email", Punch::Email.parse("nope"))
    errors.check("slug", Punch::Slug.parse("Not A Slug"))
    errors.check("name", Punch::NonEmptyString.parse("Ann"))
    called = false
    result = errors.result { called = true }
    called.should be_false
    result.should be_rejected("email", code: "invalid_email")
    result.should be_rejected("slug", code: "invalid_slug")
    result.as(Punch::Rejection).errors.size.should eq(2)
  end

  it "prefixes errors of nested objects and array elements" do
    errors = Punch::Rejection::Collector.new
    lines = errors.nested("lines")
    lines.nested(2).add("amount", Punch::Invalid.new("negative"))
    errors.add(Punch::Rejection::Path.new, Punch::Invalid.new("ends_before_start"))
    result = errors.result { nil }
    result.should be_rejected("lines", 2, "amount", code: "negative")
    result.should be_rejected(code: "ends_before_start")
  end

  it "keeps the first hundred errors, nested ones included" do
    errors = Punch::Rejection::Collector.new
    ids = errors.nested("ids")
    1000.times { |index| ids.add(index, Punch::Invalid.new("expected_integer")) }
    errors.add("q", Punch::Invalid.new("blank"))
    result = errors.result { nil }.as(Punch::Rejection)
    result.errors.size.should eq(Punch::Rejection::Collector::MAX_ERRORS)
    result.should be_rejected("ids", 99, code: "expected_integer")
  end

  it "does not let later errors change a rejection already returned" do
    errors = Punch::Rejection::Collector.new
    errors.add("a", Punch::Invalid.new("blank"))
    rejection = errors.result { nil }.as(Punch::Rejection)
    errors.add("b", Punch::Invalid.new("blank"))
    rejection.errors.size.should eq(1)
  end
end
