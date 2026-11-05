require "../spec_helper"
require "../support/json_schema_types"

private def schema(type : T.class) : JSON::Any forall T
  Punch::JSONSchema.of(type)
end

private def definition(type : T.class, name : String) : JSON::Any forall T
  schema(type)["$defs"][name]
end

private struct PagedList
  include Punch::Input

  getter limit : Punch::PageSize = Punch::PageSize.of(50)
end

private def json(text : String) : JSON::Any
  JSON.parse(text)
end

# The top-level field names an input rejects with *code*.
private def rejected(result, code : String) : Array(String)
  return [] of String unless result.is_a?(Punch::Rejection)

  result.errors.select { |error| error.code == code && error.path.size == 1 }.map(&.path.first.to_s).sort!
end

private def allows_null?(property : JSON::Any) : Bool
  if types = property["type"]?.try(&.as_a?)
    return types.includes?(JSON::Any.new("null"))
  end

  !!property["anyOf"]?.try(&.as_a.any? { |alternative| alternative["type"]? == "null" })
end

describe Punch::JSONSchema do
  describe "values" do
    it "derives scalars, times, arrays, and maps" do
      schema(String).should eq(json(%({"$schema": "#{Punch::JSONSchema::DIALECT}", "type": "string"})))
      schema(Int32)["format"].should eq("int32")
      schema(Int64)["format"].should eq("int64")
      schema(Float64)["type"].should eq("number")
      schema(Bool)["type"].should eq("boolean")
      schema(Time)["format"].should eq("date-time")
      schema(Array(Int64))["items"].should eq(json(%({"type": "integer", "format": "int64"})))
      schema(Hash(String, Bool))["additionalProperties"].should eq(json(%({"type": "boolean"})))
    end

    it "allows null for nilable types, in the type or as an alternative" do
      schema(String?)["type"].should eq(json(%(["string", "null"])))
      schema(JSONSchemaSpec::Order?)["anyOf"].should eq(json(%([{"$ref": "#/$defs/JSONSchemaSpec.Order"}, {"type": "null"}])))
    end

    it "lists other unions as alternatives" do
      schema(String | Int64)["anyOf"].should eq(json(%([{"type": "integer", "format": "int64"}, {"type": "string"}])))
    end

    it "names enums by their snake_case members, as inputs parse and to_json writes them" do
      definition(JSONSchemaSpec::Order, "JSONSchemaSpec.Order").should eq(json(%({"type": "string", "enum": ["newest_first", "oldest"]})))
      JSONSchemaSpec::Order::NewestFirst.to_json.should eq(%("newest_first"))
    end

    it "adds a primitive's own keywords to its stored type" do
      schema(Punch::Email).as_h.reject("$schema").should eq(json(%({"type": "string", "format": "idn-email", "maxLength": 254})).as_h)
      schema(Punch::Slug)["pattern"].should eq("^[a-z0-9]+(-[a-z0-9]+)*$")
      schema(Punch::NonEmptyString)["pattern"].should eq("\\S")
      schema(JSONSchemaSpec::InvoiceID).as_h.reject("$schema").should eq(json(%({"type": "integer", "format": "int64", "minimum": 1})).as_h)
    end

    it "agrees with the primitives' parsers on the examples it describes" do
      slug = Regex.new(schema(Punch::Slug)["pattern"].as_s)
      %w[annual-report-2026 a 7].each { |raw| slug.matches?(raw).should be_true; Punch::Slug.parse(raw).should be_a(Punch::Slug) }
      %w[-a a- a--b A b_c].each { |raw| slug.matches?(raw).should be_false; Punch::Slug.parse(raw).should be_a(Punch::Invalid) }
    end
  end

  describe "inputs" do
    it "shows a page size's bounds beside its default" do
      limit = definition(PagedList, "PagedList")["properties"]["limit"]
      {limit["minimum"], limit["maximum"], limit["default"]}.should eq({1, 100, 50})
      limit["type"].should eq("integer")
    end

    create = definition(JSONSchemaSpec::Create, "JSONSchemaSpec.Create")

    it "describes the body fields, with defaults, and leaves path parameters out" do
      create["type"].should eq("object")
      create["properties"].as_h.keys.should eq(%w[number recipient note copies order urgent due lines tags label rate])
      create["required"].should eq(json(%(["number", "recipient", "lines"])))
      create["properties"]["copies"]["default"].should eq(1)
      create["properties"]["order"].should eq(json(%({"$ref": "#/$defs/JSONSchemaSpec.Order", "default": "newest_first"})))
      create["properties"]["urgent"]["default"].should be_false
      create["properties"]["label"]["default"].should eq("draft")
      create["properties"]["rate"]["default"].should eq(1.5)
      create["properties"]["lines"]["items"].should eq(json(%({"$ref": "#/$defs/JSONSchemaSpec.Line"})))
      create.as_h.has_key?("additionalProperties").should be_false # unknown fields are ignored
    end

    it "requires exactly the fields the parser reports as missing" do
      registry = Punch::JSONSchema::Registry.new
      required = Punch::JSONSchema.fields(JSONSchemaSpec::Create, registry).select(&.required).map(&.name).sort!
      required.should eq(%w[invoice_id lines number recipient])
      rejected(JSONSchemaSpec::Create.from_json("{}"), "required").should eq(required)
      rejected(JSONSchemaSpec::Line.from_json("{}"), "required").should eq(definition(JSONSchemaSpec::Line, "JSONSchemaSpec.Line")["required"].as_a.map(&.as_s).sort!)
    end

    it "allows null exactly where the parser accepts it" do
      create["properties"].as_h.each do |name, property|
        result = JSONSchemaSpec::Create.from_json(%({"#{name}": null}), {"invoice_id" => "1"})
        rejected(result, "required").includes?(name).should eq(!allows_null?(property))
      end
    end

    it "lists every field, path parameters marked" do
      fields = Punch::JSONSchema.fields(JSONSchemaSpec::Create, Punch::JSONSchema::Registry.new)
      path = fields.find!(&.name.==("invoice_id"))
      {path.path, path.required, path.schema["minimum"]}.should eq({true, true, 1})
      fields.count(&.path).should eq(1)
    end

    it "handles inputs that contain themselves" do
      tree = definition(JSONSchemaSpec::Tree, "JSONSchemaSpec.Tree")
      tree["properties"]["children"]["items"].should eq(json(%({"$ref": "#/$defs/JSONSchemaSpec.Tree"})))
    end
  end

  describe "outputs" do
    shown = JSONSchemaSpec::Shown.new(JSONSchemaSpec::InvoiceID.parse(7).as(JSONSchemaSpec::InvoiceID),
      Punch::Email.parse("ann@example.org").as(Punch::Email), 1200, nil, nil, :oldest, {"a" => 1}, "x")
    shape = definition(JSONSchemaSpec::Shown, "JSONSchemaSpec.Shown")

    it "follows JSON::Field keys, ignored fields, and emit_null" do
      shape["properties"].as_h.keys.should eq(%w[id email total sent_at note order counts value])
      shape["required"].should eq(json(%(["id", "email", "total", "note", "order", "counts", "value"])))
    end

    it "describes what to_json writes" do
      written = JSON.parse(shown.to_json).as_h
      written.should eq(json(%({"id": 7, "email": "ann@example.org", "total": 1200, "note": null, "order": "oldest", "counts": {"a": 1}, "value": "x"})).as_h)
      (written.keys - shape["properties"].as_h.keys).should be_empty
      (shape["required"].as_a.map(&.as_s) - written.keys).should be_empty
    end
  end

  describe Punch::JSONSchema::Registry do
    it "defines each type once, sorted by name, under a given prefix" do
      registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
      registry.schema(JSONSchemaSpec::Create).should eq(json(%({"$ref": "#/components/schemas/JSONSchemaSpec.Create"})))
      registry.schema(Array(JSONSchemaSpec::Line))
      registry.definitions.keys.should eq(%w[JSONSchemaSpec.Create JSONSchemaSpec.Line JSONSchemaSpec.Order])
      registry.type_names["JSONSchemaSpec.Line"].should eq("JSONSchemaSpec::Line")
    end

    it "makes names OpenAPI accepts and refuses two types with one name" do
      Punch::JSONSchema.name("Page(Billing::Invoice)").should eq("Page_Billing.Invoice")
      registry = Punch::JSONSchema::Registry.new
      registry.define("A::B") { JSON::Any.new({} of String => JSON::Any) }
      expect_raises(ArgumentError, "A.B and A::B both have the schema name A.B") do
        registry.define("A.B") { JSON::Any.new({} of String => JSON::Any) }
      end
    end

    it "derives in parallel, one registry per fiber" do
      expected = schema(JSONSchemaSpec::Create)
      results = Channel(JSON::Any).new(16)
      16.times { spawn { results.send(schema(JSONSchemaSpec::Create)) } }
      16.times { results.receive.should eq(expected) }
    end
  end
end
