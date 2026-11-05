require "../spec_helper"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args : String) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::TOOL_COMMANDS)
  Run.new(code, stdout.to_s, stderr.to_s)
end

# An app with *files* under `app/`. Examples run one at a time, so changing
# the working directory is safe here.
private def in_app(files : Hash(String, String), & : ->)
  directory = File.tempname("punch-requires")
  files.each do |path, content|
    Dir.mkdir_p(File.dirname(File.join(directory, "app", path)))
    File.write(File.join(directory, "app", path), content)
  end
  begin
    Dir.cd(directory) { yield }
  ensure
    FileUtils.rm_rf(directory)
  end
end

private SLICE = {
  "setup.cr"                               => %(Punch.assets "assets"\n),
  "translations.gen.cr"                    => "struct Shop::Translations\nend\n",
  "actor.cr"                               => "struct Shop::Actor\nend\n",
  "components/layout.cr"                   => "struct Shop::Layout\nend\n",
  "billing.cr"                             => "# Billing.\nmodule Billing\nend\n",
  "billing/types.cr"                       => "module Billing\nend\n",
  "billing/events.cr"                      => "module Billing\nend\n",
  "billing/roles.cr"                       => "module Billing::Roles\nend\n",
  "billing/invoices.cr"                    => "# Invoices.\nmodule Billing::Invoices\nend\n",
  "billing/invoices/types.cr"              => "module Billing::Invoices\n  struct ID\n  end\nend\n",
  "billing/invoices/columns.cr"            => %(Punch.table "invoices", Billing::Invoices\n),
  "billing/composites.cr"                  => %(Punch.composite Billing::Address, city: String\n),
  "billing/composites.gen.cr"              => "module Billing\n  struct Address\n  end\nend\n",
  "billing/address.cr"                     => "module Billing\n  struct Address\n  end\nend\n",
  "billing/invoices/records.gen.cr"        => "module Billing::Invoices\n  record Record, id : Int64\nend\n",
  "billing/invoices/invoice.cr"            => "module Billing::Invoices\n  module Invoice\n    record Draft, id : Int64\n  end\nend\n",
  "billing/invoices/queries.gen.cr"        => "module Billing::Invoices::Queries\nend\n",
  "billing/invoices/store.cr"              => "module Billing::Invoices::Store\nend\n",
  "billing/invoices/results.cr"            => "module Billing::Invoices\nend\n",
  "billing/invoices/policies.cr"           => "module Billing::Invoices\nend\n",
  "billing/invoices/operations/send.cr"    => "module Billing::Invoices\n  struct Send\n  end\nend\n",
  "billing/invoices/jobs/remind.cr"        => "module Billing::Invoices\n  struct Remind\n  end\nend\n",
  "billing/invoices/components.cr"         => "module Billing::Invoices\nend\n",
  "billing/invoices/pages/show_page.cr"    => "module Billing::Invoices\n  struct ShowPage\n  end\nend\n",
  "billing/invoices/record.cr"             => "struct Billing::Invoices::Record\nend\n",
  "billing/payments/provider.cr"           => "module Billing::Payments\n  struct Provider\n  end\nend\n",
  "billing/invoices/subscribers/forget.cr" => "module Billing::Invoices\n  struct Forget\n  end\nend\n",
  "billing/invoices/mail/invoice_mail.cr"  => "module Billing::Invoices\n  struct InvoiceMail\n  end\nend\n",
  "billing/invoices/inputs.cr"             => "module Billing::Invoices\nend\n",
  "billing/invoices/operations/index.cr"   => "module Billing::Invoices\n  struct Index\n  end\nend\n",
  "billing/invoices/pages/index_page.cr"   => "module Billing::Invoices\n  struct IndexPage\n  end\nend\n",
  "billing/invoices/components/lines.cr"   => "module Billing::Invoices\n  struct Lines\n  end\nend\n",
  "billing/invoices/sharing.cr"            => "module Billing::Invoices::Sharing\nend\n",
  "billing/invoices/status.cr"             => "module Billing::Invoices\n  enum Status\n    Draft\n  end\nend\n",
  "billing/invoices/any.cr"                => "module Billing::Invoices\n  alias Any = Int32\nend\n",
  "billing/invoices/requires_nothing.cr"   => "# Comment only.\n",
  "billing/invoices/requires_something.cr" => "module Billing::Invoices\n  struct Other\n  end\nend\n",
}

describe "punch requires:generate" do
  it "requires every file under app/ by kind, shallow before deep, and leaves a current file alone" do
    files = SLICE.reject("billing/invoices/requires_nothing.cr", "billing/invoices/requires_something.cr")
    in_app(files) do
      run = punch("requires:generate")
      run.code.should eq(0)
      run.stdout.should eq("written   app/requires.gen.cr (#{files.size} files)\n")
      requires = File.read("app/requires.gen.cr").lines.select(&.starts_with?("require")).map(&.split('"')[1])
      requires.should eq(%w[
        ./translations.gen ./billing/types ./billing/invoices/types ./billing/events
        ./billing ./billing/invoices ./billing/composites ./billing/invoices/columns ./billing/composites.gen ./billing/invoices/records.gen
        ./actor ./billing/address ./billing/invoices/any ./billing/invoices/invoice ./billing/invoices/sharing ./billing/invoices/status ./billing/payments/provider
        ./setup
        ./billing/invoices/record ./billing/invoices/queries.gen ./billing/invoices/store
        ./billing/invoices/inputs ./billing/invoices/policies ./billing/invoices/results
        ./billing/invoices/jobs/remind ./billing/invoices/mail/invoice_mail ./billing/invoices/operations/index ./billing/invoices/operations/send ./billing/invoices/subscribers/forget
        ./components/layout ./billing/invoices/components ./billing/invoices/components/lines
        ./billing/invoices/pages/index_page ./billing/invoices/pages/show_page
        ./billing/roles
      ])
      File.read("app/requires.gen.cr").should contain("\n# outlines: X.cr beside the directory X/\nrequire \"./billing\"\n")
      punch("requires:generate").stdout.should start_with("unchanged app/requires.gen.cr")
      punch("requires:generate", "--check").code.should eq(0)
    end
  end

  it "fails the check on a stale file, naming the command" do
    in_app({"actor.cr" => "struct Shop::Actor\nend\n"}) do
      punch("requires:generate").code.should eq(0)
      File.write("app/user.cr", "struct Shop::User\nend\n")
      run = punch("requires:generate", "--check")
      run.code.should eq(1)
      run.stderr.should contain("app/requires.gen.cr does not match the files under app/. Run 'punch requires:generate'")
    end
  end

  it "refuses a file that fits no kind, naming the kinds" do
    in_app({"billing/helpers.cr" => "module Billing\n  module Formatting\n  end\nend\n", "billing/empty.cr" => "# Nothing.\n",
            "billing/setup.cr" => %(Punch.assets "assets"\n)}) do
      run = punch("requires:generate")
      run.code.should eq(1)
      run.stderr.should contain("app/billing/helpers.cr:1: no file kind fits helpers.cr: it holds Billing, Formatting but is not named after one of them (formatting.cr); name it after the type it holds")
      run.stderr.should contain("app/billing/empty.cr:1: no file kind fits empty.cr: it defines no type; ")
      run.stderr.should contain("app/billing/setup.cr:1: no file kind fits setup.cr")
      run.stderr.should contain("Each file under app/ is one of these, required in this order (lib/punch/docs/structure.md):\n  translations.gen.cr")
      File.exists?("app/requires.gen.cr").should be_false
    end
  end
end
