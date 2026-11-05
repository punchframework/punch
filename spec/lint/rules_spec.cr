require "../spec_helper"

# Punch's Ameba rules run through bin/ameba, which scripts/check.sh builds
# (about a minute in release mode) before the specs run.
private AMEBA = "#{__DIR__}/../../bin/ameba"

private def reported_lines(rule : String, fixture : String) : Array(Int32)
  output = IO::Memory.new
  Process.run(AMEBA, ["--config", "spec/lint/fixtures/ameba.yml", "--only", rule, "--format", "json", "spec/lint/fixtures/#{fixture}"],
    output: output, chdir: "#{__DIR__}/../..")
  JSON.parse(output.to_s)["sources"].as_a.flat_map(&.["issues"].as_a.map(&.["location"]["line"].as_i)).sort!
end

private def expected_lines(fixture : String, marker : String = "expect") : Array(Int32)
  File.read_lines("#{__DIR__}/fixtures/#{fixture}").each_with_index.compact_map { |line, index| index + 1 if line.ends_with?("# #{marker}") }.to_a
end

describe "Punch/DriverTypes" do
  it "reports driver types and driver requires outside the database layer" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/DriverTypes", "driver_types.cr").should eq(expected_lines("driver_types.cr"))
  end
end

describe "Punch/RecordFile" do
  it "reports a Record struct outside the file named after it" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/RecordFile", "record_file.cr").should eq(expected_lines("record_file.cr"))
  end

  it "accepts it in its own file, and nothing else there" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "billing/customers/record.cr"
    reported_lines("Punch/RecordFile", fixture).should eq(expected_lines(fixture))
  end
end

describe "Punch/OperationFile" do
  it "reports a Query, Command, or Page outside the file named after it" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/OperationFile", "app/operation_file.cr").should eq(expected_lines("app/operation_file.cr"))
  end

  it "accepts it in its own file, and only it" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/billing/invoices/operations/send.cr"
    reported_lines("Punch/OperationFile", fixture).should eq(expected_lines(fixture))
  end

  it "accepts a page in its own file under pages/, and only it" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/billing/invoices/pages/show_page.cr"
    reported_lines("Punch/OperationFile", fixture).should eq(expected_lines(fixture))
  end

  it "accepts a job in its own file under jobs/, and only it" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/billing/invoices/jobs/remind.cr"
    reported_lines("Punch/OperationFile", fixture).should eq(expected_lines(fixture))
  end

  it "applies only under app/" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/OperationFile", "operation_file.cr").should be_empty
  end
end

describe "Punch/OperationOutput" do
  it "reports an operation without `alias Output`, or whose call returns something else" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/OperationOutput", "app/operation_output.cr").should eq(expected_lines("app/operation_output.cr"))
  end

  it "applies only under app/" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/OperationOutput", "operation_output.cr").should be_empty
  end
end

describe "Punch/ModelDatabase" do
  it "reports database handles in app code outside operations and stores" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/model_database.cr"
    reported_lines("Punch/ModelDatabase", fixture).should eq(expected_lines(fixture))
  end

  it "applies only under app/, like Punch/StatusComparison" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/ModelDatabase", "driver_types.cr").should be_empty
    reported_lines("Punch/StatusComparison", "record_file.cr").should be_empty
  end
end

describe "Punch/ConstraintRescue" do
  it "reports rescuing ConstraintError in app code" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/constraint_rescue.cr"
    reported_lines("Punch/ConstraintRescue", fixture).should eq(expected_lines(fixture))
  end
end

describe "Punch/EventsHandle" do
  it "reports events handles made by hand" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/EventsHandle", "events_handle.cr").should eq(expected_lines("events_handle.cr"))
  end
end

describe "Punch/StatusComparison" do
  it "reports status comparisons inside operations" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/status_comparison.cr"
    reported_lines("Punch/StatusComparison", fixture).should eq(expected_lines(fixture))
  end
end

describe "Punch/CipherUse" do
  it "reports OpenSSL::Cipher outside Punch::Crypto" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/CipherUse", "cipher_use.cr").should eq(expected_lines("cipher_use.cr"))
  end
end

describe "Punch/MailDelivery" do
  it "reports Carbon's email class, its development and SMTP adapters, and deliver_later" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/MailDelivery", "mail_delivery.cr").should eq(expected_lines("mail_delivery.cr"))
  end
end

describe "Punch/EnvAccess" do
  it "reports ENV in app code" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/env_access.cr"
    reported_lines("Punch/EnvAccess", fixture).should eq(expected_lines(fixture))
  end

  it "applies only under app/" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/EnvAccess", "cipher_use.cr").should be_empty
  end
end

describe "Punch/TrustedHTML" do
  it "reports SafeHTML.trusted with anything but a string literal" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/TrustedHTML", "trusted_html.cr").should eq(expected_lines("trusted_html.cr"))
  end
end

describe "Punch/SQLText" do
  it "reports SQL text built from values, and accepts literals, constants, and statements built from constants" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/SQLText", "sql_text.cr").should eq(expected_lines("sql_text.cr"))
  end

  it "accepts the generator's output: a filter's value reaches only the arguments, never the statement" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    output = IO::Memory.new
    Process.run(AMEBA, ["--only", "Punch/SQLText", "--format", "json", "spec/query_gen/fixture/app/ledger/queries.gen.cr"],
      output: output, chdir: "#{__DIR__}/../..")
    summary = JSON.parse(output.to_s)["summary"]
    summary["target_sources_count"].should eq(1)
    summary["issues_count"].should eq(0)
  end
end

describe "Punch/NamespaceFile" do
  it "reports an entity directory without its outline file" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/NamespaceFile", "app/ledger/queries.gen.cr").should eq(expected_lines("app/ledger/queries.gen.cr"))
  end

  it "accepts an entity with its outline, a documented module with documented plain constants" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    {"app/billing/invoices/queries.gen.cr", "app/billing/invoices.cr"}.each do |fixture|
      reported_lines("Punch/NamespaceFile", fixture).should be_empty
    end
  end

  it "reports a doc comment on the entity's module outside its outline" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/billing/invoices/components.cr"
    reported_lines("Punch/NamespaceFile", fixture).should eq(expected_lines(fixture))
  end

  it "reports a namespace without tables and without its outline, at its first file" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/shop/returns/operations/create.cr"
    reported_lines("Punch/NamespaceFile", fixture).should eq(expected_lines(fixture))
  end

  it "reports types outside the namespace of the file's directory" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/shop/carts/store.cr"
    reported_lines("Punch/NamespaceFile", fixture).should eq(expected_lines(fixture))
  end

  it "reports an outline with code or an undocumented constant, without a doc comment, or under another name" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    {"app/shop/orders.cr", "app/shop/carts.cr", "app/shop/refunds.cr"}.each do |fixture|
      reported_lines("Punch/NamespaceFile", fixture).should eq(expected_lines(fixture))
    end
  end

  it "reports the placeholder punch generate writes into an outline" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/shop/plans.cr"
    reported_lines("Punch/NamespaceFile", fixture).should eq(expected_lines(fixture))
  end
end

describe "Punch/SetupFile" do
  it "reports app-wide declarations outside app/setup.cr, and Punch.table outside a columns.cr" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    {"app/setup_file.cr", "app/setup.cr"}.each do |fixture|
      reported_lines("Punch/SetupFile", fixture).should eq(expected_lines(fixture))
    end
  end
end

describe "Punch/PasswordCheck" do
  it "reports checking or hashing a password outside PasswordCheck" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/password_check.cr"
    reported_lines("Punch/PasswordCheck", fixture).should eq(expected_lines(fixture))
  end
end

describe "Punch/SliceBoundary" do
  it "reports another slice's tables, queries, and store" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/shop/slice_boundary.cr"
    reported_lines("Punch/SliceBoundary", fixture).should eq(expected_lines(fixture))
  end

  it "applies only under app/" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/SliceBoundary", "sql_text.cr").should be_empty
  end
end

describe "Punch/PayloadFields" do
  it "reports collections in job and event payloads" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/PayloadFields", "payload_fields.cr").should eq(expected_lines("payload_fields.cr"))
  end
end

describe "Punch/OutsideCalls" do
  it "reports HTTP, sockets, processes, and mail delivery in an operation" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/operation_effects.cr"
    reported_lines("Punch/OutsideCalls", fixture).should eq(expected_lines(fixture, "calls"))
  end
end

describe "Punch/NotNil" do
  it "reports not_nil! in app code" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    fixture = "app/operation_effects.cr"
    reported_lines("Punch/NotNil", fixture).should eq(expected_lines(fixture, "not_nil"))
  end

  it "applies only under app/" do
    pending!("bin/ameba is missing; run scripts/check.sh") unless File::Info.executable?(AMEBA)
    reported_lines("Punch/NotNil", "payload_fields.cr").should be_empty
  end
end
