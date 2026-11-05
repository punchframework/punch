require "../spec_helper"
require "../support/app_fixture"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args : String) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::TOOL_COMMANDS)
  Run.new(code, stdout.to_s, stderr.to_s)
end

private def in_shop(& : ->) : Nil
  AppFixture.copy("spec/openapi/fixture") { yield }
end

describe "punch openapi" do
  it "derives openapi.json from the app, with declared responses and doc comments" do
    in_shop do
      run = punch("openapi")
      {run.code, run.stderr}.should eq({0, ""})
      run.stdout.should eq("written   openapi.json (4 operations, 7 schemas)\n")
      document = JSON.parse(File.read("openapi.json"))
      {document["openapi"], document["info"]["title"], document["info"]["version"]}.should eq({"3.2.0", "shop", "1.2.0"})

      # Show's body returns only NotFound; its signature promises Invoice too.
      show = document["paths"]["/shop/invoices/{invoice_id}"]["get"]
      show["responses"].as_h.keys.should eq(%w[200 404 422 default])
      show["parameters"][0].should eq(JSON.parse(%({"name": "invoice_id", "in": "path", "schema": {"type": "integer", "format": "int64", "minimum": 1}, "required": true})))
      sent = document["paths"]["/shop/invoices/{invoice_id}/send"]["post"]
      sent["responses"].as_h.keys.should eq(%w[204 400 403 404 409 422 default])
      # Send knows no caller, so it takes no idempotency key.
      sent["responses"]["400"]["content"]["application/problem+json"]["schema"]["allOf"][1].should eq(JSON.parse(%({"properties": {"code": {"const": "idempotency_key_not_accepted"}}})))
      sent["parameters"].as_a.none? { |parameter| parameter["in"] == "header" }.should be_true
      sent["responses"]["403"]["content"]["application/problem+json"]["schema"]["allOf"][1].should eq(JSON.parse(%({"properties": {"code": {"const": "cross_origin_request"}}})))
      sent["responses"]["409"]["content"]["application/problem+json"]["schema"]["allOf"][1].should eq(JSON.parse(%({"properties": {"code": {"const": "already_sent"}}})))
      {sent["summary"], sent["description"]}.should eq({"Sends an invoice to its recipient.", "Sends an invoice to its recipient.\n\nOnly a draft can be sent; sending twice answers 409."})

      # Query fields are parameters, never null; Command fields are the body.
      index = document["paths"]["/shop/invoices"]["get"]
      index["parameters"][0]["schema"].should eq(JSON.parse(%({"$ref": "#/components/schemas/Shop.Invoices.State"})))
      # A result's own 422 and a rejected input are alternatives.
      created = document["paths"]["/shop/invoices"]["post"]["responses"]["422"]["content"]["application/problem+json"]["schema"]["oneOf"]
      created[0]["allOf"][1].should eq(JSON.parse(%({"properties": {"code": {"const": "duplicate_number"}}})))
      created[1].should eq(JSON.parse(%({"$ref": "#/components/schemas/Punch.ValidationProblem"})))
      document["paths"]["/shop/invoices"]["post"]["requestBody"]["content"]["application/json"]["schema"]["$ref"].should eq("#/components/schemas/Shop.Invoices.Create.Input")

      schemas = document["components"]["schemas"]
      schemas["Shop.Invoices.Invoice"]["description"].should eq("An invoice as the API shows it.")
      schemas["Shop.Invoices.Invoice"]["properties"]["number"]["description"].should eq("The number printed on the invoice.")
      schemas["Shop.Invoices.State"]["description"].should eq("Where an invoice is in its life.")

      punch("openapi").stdout.should start_with("unchanged openapi.json")
      punch("openapi", "--check").code.should eq(0)
      File.write("openapi.json", File.read("openapi.json").sub("\"1.2.0\"", "\"1.1.0\""))
      stale = punch("openapi", "--check", "--json")
      stale.code.should eq(1)
      JSON.parse(stale.stdout)["error"]["code"].should eq("stale_openapi")
    end
  end

  it "needs an app with a target" do
    in_shop do
      File.delete("shard.yml")
      JSON.parse(punch("openapi", "--json").stdout)["error"]["code"].should eq("no_app")
    end
  end
end

describe "punch openapi:diff" do
  it "fails on breaking changes unless the major version allows them" do
    directory = File.tempname("punch-diff")
    Dir.mkdir(directory)
    begin
      old = %({"info": {"version": "1.0.0"}, "paths": {"/a": {"get": {}}, "/b": {"get": {}}}})
      write = ->(name : String, text : String) { File.join(directory, name).tap { |path| File.write(path, text) } }
      before = write.call("old.json", old)
      same = write.call("same.json", old)
      removed = write.call("removed.json", %({"info": {"version": "1.1.0"}, "paths": {"/a": {"get": {}}}}))
      major = write.call("major.json", %({"info": {"version": "2.0.0"}, "paths": {"/a": {"get": {}}}}))

      punch("openapi:diff", before, same).stdout.should eq("No breaking changes.\n")
      run = punch("openapi:diff", before, removed)
      run.code.should eq(1)
      run.stderr.should eq("punch: 1 breaking change; raise the major version in shard.yml if intended:\n  GET /b: the operation was removed\n")
      JSON.parse(punch("openapi:diff", before, major, "--json").stdout).should eq(JSON.parse(%({"breaking": ["GET /b: the operation was removed"], "allowed": true})))
      punch("openapi:diff", before).code.should eq(2)
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe "punch openapi summaries" do
  it "takes the first sentence of the first paragraph, on one line" do
    summary = ->(text : String) { Punch::CLI::Commands::OpenAPIWrite.summary(text) }
    summary.call("Sends a draft: it gets the next number and is due after the\npayment term. Only a draft can be sent.").should eq("Sends a draft: it gets the next number and is due after the payment term.")
    summary.call("Lists invoices, newest\nfirst\n\nMore.").should eq("Lists invoices, newest first")
    summary.call("Checks v1.2 inputs. Then more.").should eq("Checks v1.2 inputs.")
  end
end
