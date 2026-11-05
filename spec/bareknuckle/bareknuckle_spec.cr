require "../spec_helper"
require "../../src/punch/bareknuckle"

private alias BK = Punch::Bareknuckle

private OPERATION = <<-CR
  module Billing::Invoices
    @[Punch::Authorize(ByRole)]
    struct Send < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter invoice_id : ID
      end

      alias Output = Detail | NotFound

      def call(input : Input, db : Punch::Writer) : Output
        Store.load(db, input.invoice_id) || NotFound.new
      end
    end
  end
  CR

private def change(before : String, after : String) : BK::Change
  BK::Fingerprint.change(before, after)
end

describe Punch::Bareknuckle::Fingerprint do
  it "does not see an unchanged file differently" do
    OPERATION.should contain("    alias Output")
    change(OPERATION, OPERATION).should eq(BK::Change::Body)
  end

  it "sees a changed body, a changed comment, and an added line as a body edit" do
    change(OPERATION, OPERATION.sub("|| NotFound.new", "|| NotFound.new(input.invoice_id)")).should eq(BK::Change::Body)
    change(OPERATION, OPERATION.sub("def call", "# Sends it.\n\n    def call")).should eq(BK::Change::Body)
    change(OPERATION, OPERATION.sub("Store.load", "now = 1\n      Store.load")).should eq(BK::Change::Body)
  end

  it "sees an added method or a changed signature as a signature change" do
    change(OPERATION, OPERATION.sub("alias Output", "def helper(x : Int32) : Int32\n      x\n    end\n\n    alias Output")).should eq(BK::Change::Signature)
    change(OPERATION, OPERATION.sub("db : Punch::Writer", "db : Punch::Reader")).should eq(BK::Change::Signature)
    change(OPERATION, OPERATION.sub(") : Output", ")")).should eq(BK::Change::Signature)
  end

  it "sees anything a macro reads besides methods as structure" do
    change(OPERATION, OPERATION.sub("Detail | NotFound", "Detail | NotFound | Locked")).should eq(BK::Change::Structure)
    change(OPERATION, OPERATION.sub("ByRole", "SignedIn")).should eq(BK::Change::Structure)
    change(OPERATION, OPERATION.sub("getter invoice_id : ID", "getter invoice_id : ID\n        getter note : String?")).should eq(BK::Change::Structure)
    change(OPERATION, OPERATION + "\n(").should eq(BK::Change::Structure)
  end

  it "sees changed strings alone as data where asked, and as structure otherwise" do
    catalog = "struct T\n  def none : String\n    message(1)\n  end\n\n  CATALOG = Catalog.new([\"No invoices yet.\"])\nend\n"
    changed = catalog.sub("yet", "so far")
    change(catalog, changed).should eq(BK::Change::Structure)
    BK::Fingerprint.change(catalog, changed, data: true).should eq(BK::Change::Data)
    BK::Fingerprint.change(catalog, catalog.sub("[", "[1, "), data: true).should eq(BK::Change::Structure)
  end

  it "keeps a getter's body, which Punch::Input builds its field enum from" do
    getter = "struct Input\n  include Punch::Input\n\n  def email\n    @email\n  end\nend\n"
    change(getter, getter.sub("@email", "@mail")).should eq(BK::Change::Structure)
    change(getter, getter.sub("@email", "@email.strip")).should eq(BK::Change::Structure)
  end

  it "names the methods whose bodies changed, where they start in the old file, and the calls around them" do
    methods = BK::Fingerprint.methods(OPERATION, OPERATION.sub("|| NotFound.new", "|| NotFound.new(input.invoice_id)")).should_not be_nil
    methods.changed.map(&.to_s).should eq(["Billing::Invoices::Send#call"])
    methods.changed.first.line.should eq(13)
    methods.added.should be_empty
    methods.outside.should be_false

    pasted = "record Point, x : Int32 do\n  def norm\n    x\n  end\nend\n"
    point = BK::Fingerprint.methods(pasted, pasted.sub("    x", "    x.abs")).should_not be_nil
    point.changed.map { |method| {method.name, method.line, method.anchors} }.should eq([{"norm", 2, [1]}])
  end

  it "sees no changed method for a comment, a removed and an added method, and changes outside methods" do
    comment = BK::Fingerprint.methods(OPERATION, OPERATION.sub("def call", "# Sends it.\n    def call")).should_not be_nil
    comment.changed.should be_empty
    renamed = BK::Fingerprint.methods(OPERATION, OPERATION.sub("def call", "def run")).should_not be_nil
    renamed.changed.map(&.to_s).should eq(["Billing::Invoices::Send#call"])
    renamed.added.should eq(["run"])
    catalog = "struct T\n  CATALOG = [\"No invoices yet.\"]\nend\n"
    constant = BK::Fingerprint.methods(catalog, catalog.sub("yet", "so far")).should_not be_nil
    constant.outside.should be_true
    BK::Fingerprint.methods(OPERATION, OPERATION + "\n(").should be_nil
  end
end

describe Punch::Bareknuckle::Inputs do
  it "gives each edit the tier of its kind and change" do
    BK::Inputs.tier("operations", BK::Change::Body).should eq(BK::Tier::Fast)
    BK::Inputs.tier("translations", BK::Change::Data).should eq(BK::Tier::Fast)
    BK::Inputs.tier("operations", BK::Change::Signature).should eq(BK::Tier::Full)
    BK::Inputs.tier("named", BK::Change::Signature).should eq(BK::Tier::Propagation)
    BK::Inputs.tier("store", BK::Change::Structure).should eq(BK::Tier::Full)
    BK::Inputs.tier("locale", BK::Change::Content).should eq(BK::Tier::None)
    BK::Inputs.tier("asset", BK::Change::Content).should eq(BK::Tier::None)
    BK::Inputs.tier("asset", BK::Change::Added).should eq(BK::Tier::Full)
    BK::Inputs.tier("migration", BK::Change::Added).should eq(BK::Tier::Full)
  end

  it "names what a file is to a build" do
    BK::Inputs.kind("config/locales/en.yml").should eq("locale")
    BK::Inputs.kind("app/assets/app.css").should eq("asset")
    BK::Inputs.kind("db/migrations/20261029_add.sql").should eq("migration")
    BK::Inputs.kind("db/schema.sql").should eq("schema")
    BK::Inputs.kind("app/billing/invoices/queries.sql").should eq("queries")
    BK::Inputs.kind("src/invoicing.cr").should eq("library")
    BK::Inputs.kind("app/requires.gen.cr").should eq("requires")
  end

  it "lists the files that differ, with the most expensive tier" do
    before = BK::Inputs.new({"src/a.cr" => "def a\n  1\nend\n", "src/b.cr" => "B = 1\n"}, {"config/locales/en.yml" => "x"})
    after = BK::Inputs.new({"src/a.cr" => "def a\n  2\nend\n", "src/c.cr" => "C = 1\n"}, {"config/locales/en.yml" => "y"})
    edits = after.edits(before)
    edits.map { |edit| {edit.path, edit.change} }.should eq([
      {"config/locales/en.yml", BK::Change::Content},
      {"src/a.cr", BK::Change::Body},
      {"src/b.cr", BK::Change::Removed},
      {"src/c.cr", BK::Change::Added},
    ])
    BK::Inputs.tier(edits).should eq(BK::Tier::Full)
    BK::Inputs.tier(edits.select(&.path.ends_with?("a.cr"))).should eq(BK::Tier::Fast)
    BK::Inputs.tier([] of BK::Edit).should eq(BK::Tier::None)
  end
end

describe Punch::Bareknuckle::Stats do
  output = <<-TEXT
    Parse:                             00:00:00.000085667 (   1.44MB)
    Semantic (top level):              00:00:00.558958625 ( 234.22MB)
    Semantic (main):                   00:00:03.084752168 (1083.16MB)
    Codegen (crystal):                 00:00:05.497120002 (1218.16MB)
    Codegen (bc+obj):                  00:00:01.222105584 (1322.16MB)
    Codegen (linking):                 00:00:02.540118335 (1322.16MB)

    Macro runs:
     - /crystal/src/ecr/process.cr: reused previous compilation (00:00:00.016725167)

    Codegen (bc+obj):
     - 3175/3177 .o files were reused

    These modules were not reused:
     - Billing::Invoices::Send (B-illing5858I-nvoices5858S-end.o0.bc)
     - _main (_main.o0.bc)
    TEXT

  it "reads the stage times, the heap, and the modules not reused" do
    stats = BK::Stats.parse("Semantic (main):                  \r" + output)
    stats.stages.size.should eq(6)
    stats.groups["typing"].should be_close(3.64, 0.01)
    stats.groups["link"].should be_close(2.54, 0.01)
    stats.peak_mb.should eq(1322.16)
    stats.reuse.should eq("some")
    {stats.reused, stats.total}.should eq({3175, 3177})
    stats.rebuilt.should eq(["Billing::Invoices::Send", "_main"])
  end

  it "reads all and none reused" do
    BK::Stats.parse(" - all previous .o files were reused\n").reuse.should eq("all")
    BK::Stats.parse(" - no previous .o files were reused\n").reuse.should eq("none")
    BK::Stats.parse("").reuse.should be_nil
  end

  it "strips the statistics from a failed build's output" do
    failed = "Parse:                             00:00:00.000085667 (   1.44MB)\nIn app/x.cr:3:9\n\n 3 | now = now\n\nError: expression has no effect\n"
    BK::Stats.strip(failed).should eq("In app/x.cr:3:9\n\n 3 | now = now\n\nError: expression has no effect")
    BK::Stats.strip(output).should eq("")
  end
end
