require "../spec_helper"
require "../../src/punch/cli/tool"

private BASE = <<-JSON
  {
    "openapi": "3.2.0",
    "info": {"title": "shop", "version": "1.0.0"},
    "paths": {
      "/invoices": {
        "get": {
          "parameters": [{"name": "state", "in": "query", "schema": {"$ref": "#/components/schemas/State"}}],
          "responses": {"200": {"content": {"application/json": {"schema": {"type": "array", "items": {"$ref": "#/components/schemas/Invoice"}}}}}}
        },
        "post": {
          "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Create"}}}},
          "responses": {"201": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/Invoice"}}}}}
        }
      }
    },
    "components": {
      "schemas": {
        "State": {"type": "string", "enum": ["draft", "sent"]},
        "Invoice": {
          "type": "object",
          "properties": {"id": {"type": "integer"}, "number": {"type": "string"}, "state": {"$ref": "#/components/schemas/State"}, "note": {"type": ["string", "null"]}},
          "required": ["id", "number", "state"]
        },
        "Create": {
          "type": "object",
          "properties": {"number": {"type": "string"}, "note": {"type": ["string", "null"]}, "copies": {"type": "integer"}},
          "required": ["number"]
        }
      }
    }
  }
  JSON

# BASE with *change* applied to a copy.
private def changed(& : Hash(String, JSON::Any) ->) : JSON::Any
  document = JSON.parse(BASE)
  yield document.as_h
  document
end

private def breaking(& : Hash(String, JSON::Any) ->) : Array(String)
  Punch::OpenAPI::Diff.breaking(JSON.parse(BASE), changed { |document| yield document })
end

private def schemas(document : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
  document["components"]["schemas"].as_h
end

describe Punch::OpenAPI::Diff do
  it "finds nothing between equal documents" do
    Punch::OpenAPI::Diff.breaking(JSON.parse(BASE), JSON.parse(BASE)).should be_empty
  end

  it "reports removed operations and success responses" do
    breaking { |document| document["paths"]["/invoices"].as_h.delete("post") }.should eq(["POST /invoices: the operation was removed"])
    breaking { |document| document["paths"]["/invoices"]["post"]["responses"].as_h.delete("201") }.should eq(["POST /invoices: response 201 was removed"])
  end

  it "reports requests that need more" do
    breaking { |document| schemas(document)["Create"].as_h["required"] = JSON.parse(%(["number", "copies"])) }.should eq(
      ["POST /invoices: request body: new required property copies"])
    breaking { |document| schemas(document)["Create"]["properties"].as_h["copies"] = JSON.parse(%({"type": "string"})) }.should eq(
      ["POST /invoices: request body.copies no longer accepts integer"])
    breaking { |document| schemas(document)["Create"]["properties"].as_h["note"] = JSON.parse(%({"type": "string"})) }.should eq(
      ["POST /invoices: request body.note no longer accepts null"])
    breaking { |document| schemas(document)["State"].as_h["enum"] = JSON.parse(%(["draft"])) }.should contain(
      %(GET /invoices: query parameter state no longer accepts "sent"))
    breaking do |document|
      document["paths"]["/invoices"]["get"].as_h["parameters"] = JSON.parse(%([{"name": "page", "in": "query", "required": true, "schema": {"type": "integer"}}]))
    end.should eq(["GET /invoices: new required query parameter page"])
  end

  it "reports responses that promise less" do
    breaking { |document| schemas(document)["Invoice"]["properties"].as_h.delete("number") }.should contain(
      "POST /invoices: response 201: property number was removed")
    breaking { |document| schemas(document)["Invoice"].as_h["required"] = JSON.parse(%(["id", "state"])) }.should contain(
      "GET /invoices: response 200 items: property number is no longer always present")
    breaking { |document| schemas(document)["State"].as_h["enum"] = JSON.parse(%(["draft", "sent", "paid"])) }.should contain(
      %(POST /invoices: response 201.state may now be "paid"))
  end

  it "accepts additions" do
    breaking do |document|
      document["paths"].as_h["/customers"] = JSON.parse(%({"get": {"responses": {}}}))
      schemas(document)["Create"]["properties"].as_h["due"] = JSON.parse(%({"type": "string"}))
      schemas(document)["Invoice"]["properties"].as_h["total"] = JSON.parse(%({"type": "integer"}))
      schemas(document)["Create"]["properties"].as_h["copies"] = JSON.parse(%({"type": ["integer", "string"]}))
      document["paths"]["/invoices"]["post"]["responses"].as_h["409"] = JSON.parse(%({"description": "Conflict"}))
    end.should be_empty
  end

  it "pairs the parts of a oneOf by content, not by position" do
    one_of = ->(order : String) do
      parts = %({"$ref": "#/components/schemas/Invoice"}, {"type": "object", "properties": {"errors": {"type": "array"}}, "required": ["errors"]})
      parts = %({"type": "object", "properties": {"errors": {"type": "array"}}, "required": ["errors"]}, {"$ref": "#/components/schemas/Invoice"}) if order == "swapped"
      ->(document : Hash(String, JSON::Any)) { document["paths"]["/invoices"]["post"]["responses"]["201"]["content"]["application/json"].as_h["schema"] = JSON.parse(%({"oneOf": [#{parts}]})) }
    end
    old = changed { |document| one_of.call("first").call(document) }
    Punch::OpenAPI::Diff.breaking(old, changed { |document| one_of.call("swapped").call(document) }).should be_empty
    narrowed = changed do |document|
      one_of.call("swapped").call(document)
      schemas(document)["Invoice"]["properties"].as_h.delete("number")
    end
    Punch::OpenAPI::Diff.breaking(old, narrowed).should contain("POST /invoices: response 201: property number was removed")
  end

  it "compares renamed components by content" do
    breaking do |document|
      schemas(document)["Bill"] = schemas(document).delete("Invoice") || fail "no Invoice"
      document["paths"]["/invoices"]["post"]["responses"]["201"]["content"]["application/json"].as_h["schema"] = JSON.parse(%({"$ref": "#/components/schemas/Bill"}))
      document["paths"]["/invoices"]["get"]["responses"]["200"]["content"]["application/json"]["schema"].as_h["items"] = JSON.parse(%({"$ref": "#/components/schemas/Bill"}))
    end.should be_empty
  end
end

describe Punch::CLI::Commands::OpenAPIDiff do
  it "allows breaking changes with a new major version, or a new minor one before 1.0" do
    Punch::CLI::Commands::OpenAPIDiff.major_bump?("1.4.0", "2.0.0").should be_true
    Punch::CLI::Commands::OpenAPIDiff.major_bump?("1.4.0", "1.5.0").should be_false
    Punch::CLI::Commands::OpenAPIDiff.major_bump?("0.3.1", "0.4.0").should be_true
    Punch::CLI::Commands::OpenAPIDiff.major_bump?("0.3.1", "0.3.2").should be_false
    Punch::CLI::Commands::OpenAPIDiff.major_bump?(nil, "1.0.0").should be_false
  end
end
