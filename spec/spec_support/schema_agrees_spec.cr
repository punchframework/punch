require "../spec_helper"

module SchemaAgreesSpec
  # Parse and schema say the same: 1 to 10.
  struct Level
    include Punch::Primitive(Int64)

    def self.json_schema
      {minimum: 1, maximum: 10}
    end

    def self.parse(raw : Int) : self | Punch::Invalid
      raw >= 1 && raw <= 10 ? new(raw.to_i64) : Punch::Invalid.new("out_of_range")
    end
  end

  # The parser was changed to 12 and the schema was not.
  struct Drifted
    include Punch::Primitive(Int64)

    def self.json_schema
      {minimum: 1, maximum: 10}
    end

    def self.parse(raw : Int) : self | Punch::Invalid
      raw >= 1 && raw <= 12 ? new(raw.to_i64) : Punch::Invalid.new("out_of_range")
    end
  end

  # No schema keywords of its own, so the schema accepts any string.
  struct Plain
    include Punch::Primitive(String)

    def self.parse(raw : String) : self | Punch::Invalid
      raw.starts_with?("p") ? new(raw) : Punch::Invalid.new("not_p")
    end
  end
end

describe "Punch::Spec.schema_agrees" do
  it "passes when parse and the schema accept and refuse the same samples" do
    Punch::Spec.schema_agrees(SchemaAgreesSpec::Level, valid: [1_i64, 10_i64], invalid: [0_i64, 11_i64, -3_i64])
  end

  it "names each sample the two disagree on" do
    error = expect_raises(Spec::AssertionFailed) do
      Punch::Spec.schema_agrees(SchemaAgreesSpec::Drifted, valid: [10_i64, 11_i64], invalid: [0_i64, 11_i64])
    end
    error.message.to_s.should contain("SchemaAgreesSpec::Drifted.json_schema and SchemaAgreesSpec::Drifted.parse disagree")
    error.message.to_s.should contain("11 should be valid: parse accepts it, the schema refuses it")
    error.message.to_s.should contain("11 should be invalid: parse accepts it, the schema refuses it")
    error.message.to_s.should_not contain("10 should")
    error.message.to_s.should_not contain("0 should")
  end

  it "catches a schema that says less than the parser" do
    error = expect_raises(Spec::AssertionFailed) { Punch::Spec.schema_agrees(SchemaAgreesSpec::Plain, valid: ["pa"], invalid: ["a"]) }
    error.message.to_s.should contain(%("a" should be invalid: parse refuses it, the schema accepts it))
  end
end
