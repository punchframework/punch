require "../spec_helper"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args : String) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::TOOL_COMMANDS)
  Run.new(code, stdout.to_s, stderr.to_s)
end

private SEND = <<-CRYSTAL
  require "./shared"

  module Billing::Invoices
    # An invoice without lines cannot be sent.
    @[Punch::Status(422)]
    struct NoLines
      include Punch::Problem
    end

    # Sends a draft.
    @[Punch::Authorize(ByRole)]
    struct Send < Punch::Command
      struct Input
        include Punch::Input
        getter invoice_id : Int64
      end

      def call(input : Input, db : Punch::Writer) : NoLines
        # Not yet.
        NoLines.new
      end
    end
  end

  CRYSTAL

private SEND_QUOTE = <<-CRYSTAL
  # app/billing/invoices/operations/send.cr
  module Billing::Invoices
    # ...

    # Sends a draft.
    @[Punch::Authorize(ByRole)]
    struct Send < Punch::Command
      struct Input
        include Punch::Input
        getter invoice_id : Int64
      end

      def call(input : Input, db : Punch::Writer) : NoLines
        # ...
      end
    end
  end
  CRYSTAL

private QUERIES = <<-SQL
  -- name: Find :one
  SELECT * FROM invoices WHERE id = :id;

  -- name: Count :one
  SELECT count(*) FROM invoices;

  SQL

private FAILING = <<-CRYSTAL
  struct Leak
    getter token = Punch::Secret.new("t")
  end

  Leak.new.to_json

  CRYSTAL

private GUIDE = <<-MARKDOWN
  # Jobs

  Applies to Punch 0.4.

  ## Sending

  ```crystal source=reference/app/billing/invoices/operations/send.cr select=Billing::Invoices::Send elide=call
  #{SEND_QUOTE}
  ```

  ```sql source=reference/app/billing/invoices/queries.sql select=Count
  -- app/billing/invoices/queries.sql
  -- name: Count :one
  SELECT count(*) FROM invoices;
  ```

  ```yaml source=reference/config/locales/en.yml select=en.accounts
  # config/locales/en.yml
  en:
    # ...
    accounts:
      signed_in: Welcome
  ```

  ```crystal fails=spec/fail/secret_to_json.cr
  #{FAILING.chomp}
  ```

  ```text
  Error: Punch::Secret cannot be serialized to JSON
  ```

  ```ruby illustrative
  invoice.update!(sent: true)
  ```

  ```console
  $ punch check
  ```

  See [the reference](../jobs.md#retries) and [below](#rules).

  ## Rules

  - Never send from `call`.
  MARKDOWN

private INDEX = <<-TEXT
  # Punch

  ## Guides

  - [Punch documentation](README.md): the front page.
  - [Guides](guides/README.md): by group.
  - [Jobs](guides/jobs.md): background work.
  - [When the Compiler Says No](guides/when-the-compiler-says-no.md): errors.

  ## Reference

  - [Background jobs](jobs.md): the queue.
  - [Compile errors](reference/compile-errors.md): the messages.
  - [Core types](core-types.md): primitives.
  TEXT

private FRONT = <<-MARKDOWN
  # Punch documentation

  - [Guides](guides/README.md)
  - [Background jobs](jobs.md)
  - [Compile errors](reference/compile-errors.md)
  - [Core types](core-types.md)
  MARKDOWN

# Punch's repository in miniature: a guide, a reference page, the index,
# the reference app's files the guide quotes, and a failing fixture.
private def in_repository(& : ->)
  directory = File.tempname("punch-docs")
  files = {
    "shard.yml"                                         => "name: punch\nversion: 0.4.2\n",
    "docs/llms.txt"                                     => INDEX,
    "docs/README.md"                                    => FRONT,
    "docs/guides/README.md"                             => "# Guides\n\n- [Jobs](jobs.md)\n- [When the Compiler Says No](when-the-compiler-says-no.md)\n",
    "docs/jobs.md"                                      => "# Background jobs\n\n## Retries\n\nLearn it in [Jobs](guides/jobs.md).\n",
    "docs/core-types.md"                                => "# Core types\n",
    "docs/guides/jobs.md"                               => GUIDE,
    "docs/guides/when-the-compiler-says-no.md"          => "# When the Compiler Says No\n\nApplies to Punch 0.4.\n\n## Rules\n\n- Read the last line.\n",
    "reference/app/billing/invoices/operations/send.cr" => SEND,
    "reference/app/billing/invoices/queries.sql"        => QUERIES,
    "reference/config/locales/en.yml"                   => "en:\n  billing:\n    sent: Sent\n  accounts:\n    signed_in: Welcome\n",
    "spec/fail/secret_to_json.cr"                       => %(require "../../src/punch"\n\n#{FAILING}),
    "spec/core/compile_errors_spec.cr"                  => %(COMPILE_ERRORS = {\n  "secret_to_json" => "Punch::Secret cannot be serialized to JSON",\n}\n),
    "src/punch/jobs.cr"                                 => "# A job's retries (lib/punch/docs/jobs.md#retries).\n",
    "template/AGENTS.md.ecr"                            => "Read lib/punch/docs/jobs.md first.\n",
  }
  files.each do |path, content|
    Dir.mkdir_p(File.dirname(File.join(directory, path)))
    File.write(File.join(directory, path), content)
  end
  begin
    Dir.cd(directory) do
      Punch::DocsCheck::Generated.pages.each do |page|
        Dir.mkdir_p(File.dirname(page.path))
        File.write(page.path, page.text.as(String))
      end
      yield
    end
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def edit(path : String, & : String -> String) : Nil
  File.write(path, yield File.read(path))
end

private def problems : Array(String)
  run = punch("docs:check", "--json")
  run.code.should eq(1)
  JSON.parse(run.stdout)["error"]["details"]["problems"].as_a.map { |problem| "#{problem["path"]}:#{problem["line"]}: #{problem["message"]}" }
end

describe "punch docs:check" do
  it "passes when every block is quoted, failing, illustrative, or a console, and every link resolves" do
    in_repository do
      run = punch("docs:check")
      run.stderr.should eq("")
      run.code.should eq(0)
      run.stdout.should eq("7 pages, 3 quotes, 21 links: all current.\n")
    end
  end

  it "quotes a definition inside the modules that hold it, siblings and elided bodies as `# ...`" do
    in_repository do
      File.read("docs/guides/jobs.md").should contain(SEND_QUOTE)
      Punch::DocsCheck::Quote.new("reference/app/billing/invoices/operations/send.cr", "crystal", "Billing::Invoices::NoLines,Billing::Invoices::Send#call", nil).text.should eq(<<-CRYSTAL)
        # app/billing/invoices/operations/send.cr
        module Billing::Invoices
          # An invoice without lines cannot be sent.
          @[Punch::Status(422)]
          struct NoLines
            include Punch::Problem
          end

          # Sends a draft.
          @[Punch::Authorize(ByRole)]
          struct Send < Punch::Command
            # ...

            def call(input : Input, db : Punch::Writer) : NoLines
              # Not yet.
              NoLines.new
            end
          end
        end
        CRYSTAL
    end
  end

  it "leaves out doc comments and annotations with bare, as `# ...`" do
    in_repository do
      Punch::DocsCheck::Quote.new("reference/app/billing/invoices/operations/send.cr", "crystal", "Billing::Invoices::Send", "call", bare: "").text.should eq(<<-CRYSTAL)
        # app/billing/invoices/operations/send.cr
        module Billing::Invoices
          # ...
          struct Send < Punch::Command
            struct Input
              include Punch::Input
              getter invoice_id : Int64
            end

            def call(input : Input, db : Punch::Writer) : NoLines
              # ...
            end
          end
        end
        CRYSTAL
      Punch::DocsCheck::Quote.new("reference/app/billing/invoices/operations/send.cr", "crystal", "Billing::Invoices::NoLines,Billing::Invoices::Send#call", nil, bare: "Billing::Invoices::Send").text.should eq(<<-CRYSTAL)
        # app/billing/invoices/operations/send.cr
        module Billing::Invoices
          # An invoice without lines cannot be sent.
          @[Punch::Status(422)]
          struct NoLines
            include Punch::Problem
          end

          # ...
          struct Send < Punch::Command
            # ...

            def call(input : Input, db : Punch::Writer) : NoLines
              # Not yet.
              NoLines.new
            end
          end
        end
        CRYSTAL
    end
  end

  it "quotes a method inside a record, with the record's fields" do
    in_repository do
      Dir.mkdir_p("reference/app/jobs")
      File.write("reference/app/jobs/remind.cr", <<-CRYSTAL)
        module Billing
          # Reminds a customer.
          record Remind,
            invoice_id : Int64,
            channel : String do
            include Punch::Job

            def perform(job : Punch::Job::Context) : Punch::Job::Result
              nil
            end

            def label : String
              channel
            end
          end
        end

        CRYSTAL
      Punch::DocsCheck::Quote.new("reference/app/jobs/remind.cr", "crystal", "Billing::Remind#perform", nil).text.should eq(<<-CRYSTAL)
        # app/jobs/remind.cr
        module Billing
          # Reminds a customer.
          record Remind,
            invoice_id : Int64,
            channel : String do
            # ...

            def perform(job : Punch::Job::Context) : Punch::Job::Result
              nil
            end

            # ...
          end
        end
        CRYSTAL
    end
  end

  it "quotes one composite of a columns.cr by its name" do
    in_repository do
      Dir.mkdir_p("reference/app/billing")
      File.write("reference/app/billing/columns.cr", <<-CRYSTAL)
        # Columns of billing.

        # A postal address.
        Punch.composite Billing::Address,
          street: Punch::NonEmptyString,
          city: Punch::NonEmptyString

        Punch.table "sites", Billing::Sites,
          address: {type: Billing::Address, columns: "address_"}
        CRYSTAL
      Punch::DocsCheck::Quote.new("reference/app/billing/columns.cr", "crystal", "Billing::Address", nil).text.should eq(<<-CRYSTAL)
        # app/billing/columns.cr
        # A postal address.
        Punch.composite Billing::Address,
          street: Punch::NonEmptyString,
          city: Punch::NonEmptyString

        # ...
        CRYSTAL
    end
  end

  it "quotes an example by its full description, with the helpers it names" do
    in_repository do
      Dir.mkdir_p("reference/spec")
      File.write("reference/spec/send_spec.cr", <<-CRYSTAL)
        require "../spec_helper"

        private def client
          Punch::Spec.client
        end

        describe "sending an invoice" do
          it "refuses a draft without lines" do
            client.post("/").status.code.should eq(422)
          end

          it "sends a draft, once" do
            client.post("/").status.code.should eq(200)
          end
        end

        CRYSTAL
      Punch::DocsCheck::Quote.new("reference/spec/send_spec.cr", "crystal", "#client,sending an invoice sends a draft, once", nil).text.should eq(<<-CRYSTAL)
        # spec/send_spec.cr
        private def client
          Punch::Spec.client
        end

        describe "sending an invoice" do
          # ...

          it "sends a draft, once" do
            client.post("/").status.code.should eq(200)
          end
        end
        CRYSTAL
    end
  end

  it "selects a YAML key among the direct children of the one before it" do
    in_repository do
      File.write("reference/config/locales/de.yml", "de:\n  layout:\n    invoices: Rechnungen\n  invoices:\n    numbered: Rechnung %{number}\n    draft: Entwurf\n")
      Punch::DocsCheck::Quote.new("reference/config/locales/de.yml", "yaml", "de.invoices.numbered", nil).text.should eq(<<-YAML)
        # config/locales/de.yml
        de:
          # ...
          invoices:
            numbered: Rechnung %{number}
        YAML
      Punch::DocsCheck::Quote.new("reference/config/locales/de.yml", "yaml", "de.invoices.draft", nil).text.should eq(<<-YAML)
        # config/locales/de.yml
        de:
          # ...
          invoices:
            # ...
            draft: Entwurf
        YAML
    end
  end

  it "names what a file defines when a selection is not among them" do
    in_repository do
      edit("docs/guides/jobs.md", &.sub("select=Billing::Invoices::Send elide", "select=Billing::Invoices::Sent elide"))
      problems.first.should contain("send.cr defines no Billing::Invoices::Sent. It defines: Billing::Invoices, Billing::Invoices::NoLines, Billing::Invoices::Send")
    end
  end

  it "fails on a stale copy, and --write refreshes it" do
    in_repository do
      edit("reference/app/billing/invoices/queries.sql", &.sub("count(*)", "count(id)"))
      problems.should eq(["docs/guides/jobs.md:27: This copy of reference/app/billing/invoices/queries.sql (Count) differs from the source. Run 'punch docs:check --write' and review the change."])
      run = punch("docs:check", "--write")
      run.code.should eq(0)
      run.stdout.should start_with("written   docs/guides/jobs.md\n")
      File.read("docs/guides/jobs.md").should contain("SELECT count(id) FROM invoices;\n```\n\n```yaml")
      punch("docs:check").code.should eq(0)
    end
  end

  it "refuses a code block that says nothing about what keeps it true" do
    in_repository do
      edit("docs/guides/jobs.md", &.sub("```ruby illustrative", "```ruby"))
      edit("docs/guides/jobs.md", &.sub("## Rules", "```crystal illustrative\nx\n```\n\n## Rules"))
      problems.should eq([
        "docs/guides/jobs.md:53: A code block in a guide is quoted (source=PATH select=NAME), fails (fails=spec/fail/NAME.cr), illustrative (illustrative=\"why\"), console, or text; this one is 'ruby'.",
        %(docs/guides/jobs.md:63: An illustrative crystal block names why it is not quoted: illustrative="fragment of Send#call".),
      ])
    end
  end

  it "wants the failing example's fixture and the compiler's message after it" do
    in_repository do
      edit("docs/guides/jobs.md", &.sub("Error: Punch::Secret cannot be serialized to JSON", "Error: something"))
      problems.should eq(["docs/guides/jobs.md:41: The 'text' block after a failing example holds the compiler's message, which includes: Punch::Secret cannot be serialized to JSON"])
    end
  end

  it "fails on links and lib/punch/docs paths that lead nowhere" do
    in_repository do
      edit("docs/jobs.md", &.sub("## Retries", "## Retrying"))
      edit("template/AGENTS.md.ecr", &.sub("jobs.md", "queue.md"))
      problems.should eq([
        "docs/guides/jobs.md:61: The link to ../jobs.md#retries leads nowhere: docs/jobs.md has no heading with the anchor '#retries'.",
        "src/punch/jobs.cr:1: The link to lib/punch/docs/jobs.md#retries leads nowhere: docs/jobs.md has no heading with the anchor '#retries'.",
        "template/AGENTS.md.ecr:1: The link to lib/punch/docs/queue.md leads nowhere: docs/queue.md does not exist.",
      ])
    end
  end

  it "wants every page in the index, and in each guide the version line and Rules" do
    in_repository do
      File.write("docs/cache.md", "# Cache\n")
      edit("docs/guides/jobs.md", &.sub("Applies to Punch 0.4.", "Applies to Punch 0.3.").sub("## Rules", "## Invariants"))
      problems.should eq([
        "docs/guides/jobs.md:3: The version line reads 'Applies to Punch 0.3.'; this Punch is 'Applies to Punch 0.4.'.",
        "docs/guides/jobs.md:65: A topic guide ends with a '## Rules' section: its invariants as short imperative lines.",
        "docs/guides/jobs.md:61: The link to #rules leads nowhere: docs/guides/jobs.md has no heading with the anchor '#rules'.",
        "docs/llms.txt:1: docs/cache.md is not in the index. Add a line: - [Title](cache.md): what it answers.",
        "docs/README.md:1: docs/cache.md is not linked from docs/README.md (the front page for people). Add a line: - [Title](cache.md): what it answers.",
      ])
    end
  end

  it "wants every guide in the guides' index, and the front page" do
    in_repository do
      File.write("docs/guides/caching.md", "# Caching\n\nApplies to Punch 0.4.\n\n## Rules\n\n- Forget by events.\n")
      File.delete("docs/README.md")
      problems.should contain("docs/guides/README.md:1: docs/guides/caching.md is not linked from docs/guides/README.md (the guides by group). Add a line: - [Title](caching.md): what it answers.")
      problems.should contain("docs/README.md:1: docs/README.md is missing: the front page for people, linking every page.")
    end
  end

  it "writes the reference tables from their sources, and fails when one is stale" do
    in_repository do
      File.read("docs/reference/compile-errors.md").should contain("## Core types\n\nExplained in [Core types](../core-types.md).\n\n| Message | Example |\n|---|---|\n" \
                                                                   "| `Punch::Secret cannot be serialized to JSON` | [secret_to_json](../../spec/fail/secret_to_json.cr) |\n")
      edit("spec/core/compile_errors_spec.cr", &.sub("serialized to JSON", "turned into JSON"))
      edit("docs/guides/jobs.md", &.sub("serialized to JSON", "turned into JSON"))
      problems.should contain("docs/reference/compile-errors.md:1: docs/reference/compile-errors.md does not match spec/core/compile_errors_spec.cr and spec/fail/. Run 'punch docs:check --write'; never edit it by hand.")
      punch("docs:check", "--write").stdout.should contain("written   docs/reference/compile-errors.md")
      File.read("docs/reference/compile-errors.md").should contain("turned into JSON")
    end
  end

  it "wants a topic for every failing fixture" do
    in_repository do
      edit("spec/core/compile_errors_spec.cr", &.sub(%("secret_to_json"), %("zebra_crossing")))
      problems.first.should eq("spec/core/compile_errors_spec.cr:1: The fixture zebra_crossing fits no topic: add its prefix to Punch::DocsCheck::Generated::TOPICS.")
    end
  end

  it "checks a quoted message against the source that gives it, interpolations as any text" do
    in_repository do
      File.write("src/punch/lint.cr", %(MSG = "`%s` is built from a value: bind it " \\\n      "as a parameter (lib/punch/docs/jobs.md)"\nraise Error.new("\#{name} waits in \#{queue.size} queues")\n))
      message = "```text message=src/punch/lint.cr\n`Send` is built from a value: bind it as a parameter (lib/punch/docs/jobs.md)\nRemind waits in 2 queues\n```\n\n## Rules"
      edit("docs/guides/jobs.md", &.sub("## Rules", message))
      punch("docs:check").code.should eq(0)

      edit("docs/guides/jobs.md", &.sub("bind it as a parameter", "bind it"))
      edit("docs/guides/jobs.md", &.sub("Remind waits", "Remind still waits"))
      problems.size.should eq(1)
      problems.first.should start_with("docs/guides/jobs.md:63: This message is not in src/punch/lint.cr: each line of the block is a string there, to its end")
    end
  end

  it "finds a translation's message anywhere in a block, such as inside a JSON answer" do
    in_repository do
      File.write("src/punch/en.yml", "en:\n  errors:\n    blank: \"Must not be empty.\"\n    too_long: \"Must be at most %{max} characters long.\"\n")
      message = %(```text message=src/punch/en.yml\n{"errors":[{"code":"too_long","message":"Must be at most 80 characters long."}]}\n```\n\n## Rules)
      edit("docs/guides/jobs.md", &.sub("## Rules", message))
      punch("docs:check").code.should eq(0)
      edit("docs/guides/jobs.md", &.sub("at most 80", "no more than 80"))
      problems.first.should contain("This message is not in src/punch/en.yml")
    end
  end

  it "wants every message under Common mistakes to name its source" do
    in_repository do
      edit("docs/guides/jobs.md", &.sub("## Rules", "## Common mistakes\n\n```text\nError: case is not exhaustive.\n```\n\n## Rules"))
      problems.should eq([%(docs/guides/jobs.md:65: A message under "Common mistakes" names the file it comes from, so it stays current: a 'text message=src/punch/ameba/sql_text.cr' block, or 'message=crystal' (sqlite, turbo) for another program's.)])
      edit("docs/guides/jobs.md", &.sub("```text\nError: case", "```text message=crystal\nError: case"))
      punch("docs:check").code.should eq(0)
    end
  end

  it "reads the string literals of a Crystal file, in macros too, as text and gaps" do
    source = <<-'CRYSTAL'
      # "a comment is not a message at all"
      quote = '"'
      ONE = "first part of it " \
            "and the #{name} rest\n"
      {% raise "#{@type} needs a policy, " +
               "or @[Punch::Public] {{ x }}" %}
      RAW = %q(LIKE needs ESCAPE '\', always)
      LIST = %w[a b]
      x = 7 % (2)
      CRYSTAL
    Punch::DocsCheck::Messages::Literals.new(source).all.should eq([
      ["first part of it and the ", nil, " rest\n"],
      [nil, " needs a policy, or @[Punch::Public] ", nil],
      ["LIKE needs ESCAPE '\\', always"],
    ])
  end

  it "gives headings GitHub's anchors" do
    Punch::DocsCheck.slug("Field errors from `Punch::Rejection`").should eq("field-errors-from-punchrejection")
    Punch::DocsCheck.slug("Links: [the index](llms.txt), again").should eq("links-the-index-again")
  end
end
