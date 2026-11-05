require "../spec_helper"
require "../support/json_schema_types"

private def json(text : String) : JSON::Any
  JSON.parse(text)
end

private def violations(value : String, schema : String) : Array(String)
  Punch::JSONSchema.validate(json(value), json(schema)).map(&.to_s)
end

describe "Punch::JSONSchema.validate" do
  it "checks types, with integers as numbers and null only where allowed" do
    violations(%(1), %({"type": "number"})).should be_empty
    violations(%(1.0), %({"type": "integer"})).should be_empty
    violations(%(1.5), %({"type": "integer"})).should eq(["(root): expected integer, got number (type)"])
    violations(%(null), %({"type": ["string", "null"]})).should be_empty
    violations(%(null), %({"type": "string"})).should eq(["(root): expected string, got null (type)"])
    violations(%("x"), %(false)).should eq(["(root): no value is allowed here (false)"])
    violations(%("x"), %(true)).should be_empty
  end

  it "reports every violation with its JSON Pointer" do
    schema = <<-JSON
      {"type": "object", "required": ["id", "lines"], "properties": {
        "id": {"type": "integer", "minimum": 1},
        "lines": {"type": "array", "items": {"type": "object", "properties": {"a/b": {"type": "string", "maxLength": 2}}}}}}
      JSON
    violations(%({"id": 0, "lines": [{"a/b": "ok"}, {"a/b": "long"}]}), schema).should eq([
      "/id: 0 fails minimum 1.0 (minimum)",
      "/lines/1/a~1b: 4 characters, at most 2 expected (maxLength)",
    ])
    violations(%({}), schema).should eq([%((root): "id" is missing (required)), %((root): "lines" is missing (required))])
  end

  it "checks strings: length in characters, unanchored patterns, date-time" do
    violations(%("äö"), %({"maxLength": 2, "minLength": 2})).should be_empty
    violations(%("  x "), %({"pattern": "\\\\S"})).should be_empty
    violations(%("   "), %({"pattern": "\\\\S"})).should eq([%((root): "   " does not match \\S (pattern))])
    violations(%("2026-10-08T09:30:00Z"), %({"format": "date-time"})).should be_empty
    violations(%("2026-10-08"), %({"format": "date-time"})).size.should eq(1)
    violations(%("anything"), %({"format": "idn-email"})).should be_empty # an annotation
  end

  it "checks number bounds and integer formats" do
    violations(%(2147483648), %({"type": "integer", "format": "int32"})).should eq(["(root): 2147483648 is outside int32 (format)"])
    violations(%(2147483648), %({"type": "integer", "format": "int64"})).should be_empty
    violations(%(5), %({"exclusiveMaximum": 5, "exclusiveMinimum": 5})).size.should eq(2)
  end

  it "checks enum, const, additionalProperties, and arrays" do
    violations(%("c"), %({"enum": ["a", "b"]})).should eq([%((root): "c" is not one of ["a","b"] (enum))])
    violations(%({"a": 1, "b": "x"}), %({"additionalProperties": {"type": "integer"}})).should eq(["/b: expected integer, got string (type)"])
    violations(%({"a": 1}), %({"properties": {}, "additionalProperties": false})).should eq(["/a: no value is allowed here (false)"])
    violations(%([1, "x", true]), %({"prefixItems": [{"type": "integer"}, {"type": "string"}], "items": {"type": "boolean"}, "maxItems": 2})).should eq(["(root): 3 items, at most 2 expected (maxItems)"])
  end

  it "combines schemas with allOf, anyOf, oneOf, and not" do
    violations(%(3), %({"allOf": [{"minimum": 1}, {"maximum": 2}]})).should eq(["(root): 3 fails maximum 2.0 (maximum)"])
    violations(%("x"), %({"anyOf": [{"type": "integer"}, {"type": "null"}]})).should eq(["(root): string matches none of 2 alternatives (anyOf)"])
    violations(%(1), %({"oneOf": [{"type": "integer"}, {"type": "number"}]})).should eq(["(root): integer matches 2 of 2 alternatives, exactly one expected (oneOf)"])
    violations(%(1), %({"not": {"type": "integer"}})).should eq(["(root): integer matches a schema it must not (not)"])
  end

  it "follows $ref within the document, recursively" do
    document = json(<<-JSON)
      {"components": {"schemas": {"Tree": {"type": "object", "required": ["name"], "properties": {
        "name": {"type": "string"}, "children": {"type": "array", "items": {"$ref": "#/components/schemas/Tree"}}}}}}}
      JSON
    tree = json(%({"name": "a", "children": [{"name": "b", "children": [{"children": []}]}]}))
    schema = json(%({"$ref": "#/components/schemas/Tree"}))
    Punch::JSONSchema.validate(tree, schema, root: document).map(&.to_s).should eq([%(/children/0/children/0: "name" is missing (required))])
    expect_raises(ArgumentError, "#/components/schemas/Gone does not resolve") do
      Punch::JSONSchema.validate(tree, json(%({"$ref": "#/components/schemas/Gone"})), root: document)
    end
  end

  it "accepts what derived schemas describe: to_json of outputs, and what inputs parse" do
    shown = JSONSchemaSpec::Shown.new(JSONSchemaSpec::InvoiceID.parse(7).as(JSONSchemaSpec::InvoiceID),
      Punch::Email.parse("ann@example.org").as(Punch::Email), 1200, Time.utc(2026, 10, 8), nil, :oldest, {"a" => 1}, 5_i64)
    JSON.parse(shown.to_json).should match_schema(Punch::JSONSchema.of(JSONSchemaSpec::Shown))

    body = json(%({"number": "inv-1", "recipient": "ann@example.org", "lines": [{"description": "x", "quantity": 1, "unit_cents": 5}], "copies": 2}))
    JSONSchemaSpec::Create.from_json(body.to_json, {"invoice_id" => "3"}).should be_a(JSONSchemaSpec::Create)
    body.should match_schema(Punch::JSONSchema.of(JSONSchemaSpec::Create))

    wrong = json(%({"number": "Not A Slug", "recipient": "ann@example.org", "lines": [{"description": " ", "quantity": 1, "unit_cents": 5}]}))
    JSONSchemaSpec::Create.from_json(wrong.to_json, {"invoice_id" => "3"}).should be_a(Punch::Rejection)
    wrong.should_not match_schema(Punch::JSONSchema.of(JSONSchemaSpec::Create))
    Punch::JSONSchema.validate(wrong, Punch::JSONSchema.of(JSONSchemaSpec::Create)).map(&.pointer).should eq(["/number", "/lines/0/description"])
  end
end
