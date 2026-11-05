module Punch::Spec
  # Checks that a primitive's `json_schema` says what its `parse` does: each
  # *valid* sample must be accepted by `parse` and by the type's JSON Schema
  # (`Punch::JSONSchema.of`), and each *invalid* one refused by both. The
  # schema restates the parser's rule, in the OpenAPI document and in forms,
  # and nothing else keeps the two the same (docs/json-schema.md).
  #
  # ```
  # Punch::Spec.schema_agrees(Billing::Invoices::Quantity, valid: [1_i64, 10_000_i64], invalid: [0_i64, 10_001_i64, -5_i64])
  # ```
  #
  # Samples are raw values of the stored type. Put each boundary in: the
  # last value in and the first value out on each side. One failure lists
  # every sample the two disagree on, or both get wrong.
  def self.schema_agrees(type : T.class, *, valid : Array, invalid : Array, file = __FILE__, line = __LINE__) : Nil forall T
    schema = JSONSchema.of(type)
    problems = [] of String
    {valid: valid, invalid: invalid}.each do |kind, samples|
      expected = kind == :valid
      samples.each do |sample|
        parsed = !T.parse(sample).is_a?(Invalid)
        described = JSONSchema.validate(JSON.parse(sample.to_json), schema, schema).empty?
        next if parsed == expected && described == expected
        problems << "#{sample.inspect} should be #{kind}: parse #{parsed ? "accepts" : "refuses"} it, the schema #{described ? "accepts" : "refuses"} it"
      end
    end
    return if problems.empty?

    fail "#{T}.json_schema and #{T}.parse disagree:\n  #{problems.join("\n  ")}", file, line
  end
end
