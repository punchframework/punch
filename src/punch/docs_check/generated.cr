require "compiler/crystal/syntax"

module Punch::DocsCheck
  # The reference pages written from their sources, never by hand:
  # `docs:check --write` writes them, and `docs:check` fails when one is
  # stale.
  module Generated
    HEADER = "<!-- Written by `punch docs:check --write` from %s. Do not edit: change the source and run it again. -->"

    # Fixture name prefixes and the topic each belongs to, longest first
    # where one prefix starts another. A fixture that fits none fails the
    # check, so a new one gets a topic.
    TOPICS = [
      {"own_password", "auth"}, {"password", "auth"}, {"second_factor", "auth"}, {"own_second_factor", "auth"},
      {"challenge", "auth"}, {"reveal", "auth"}, {"auth", "auth"},
      {"rate_limit", "rate-limits"}, {"command_without_rate_limit", "rate-limits"},
      {"record_as_response", "openapi"}, {"problem", "openapi"}, {"status", "openapi"},
      {"raw_request", "operations"}, {"query_with_writer", "operations"}, {"route", "operations"}, {"path", "operations"},
      {"operation", "operations"}, {"idempotency", "operations"},
      {"query_exec", "persistence"}, {"sql", "persistence"},
      {"typed_id", "core-types"}, {"public_id", "core-types"}, {"primitive", "core-types"}, {"secret", "core-types"},
      {"input", "input"},
      {"migrations", "migrations"}, {"migration", "migrations"},
      {"columns", "queries"}, {"stored", "queries"}, {"encrypted", "queries"}, {"blind_index", "queries"}, {"like_text", "queries"}, {"filter", "queries"}, {"violation", "queries"},
      {"behaviour", "models"},
      {"schema", "json-schema"},
      {"credentials", "credentials"},
      {"cache", "cache"}, {"forget", "cache"}, {"versioned", "cache"},
      {"asset", "assets"},
      {"view", "views"}, {"page", "views"}, {"query_named_page", "views"}, {"href", "views"}, {"forms", "views"}, {"form", "views"},
      {"live", "views"}, {"agent", "views"},
      {"policy", "authorization"}, {"role", "authorization"},
      {"events", "events"}, {"event", "events"}, {"subscriber", "events"},
      {"jobs", "jobs"}, {"job", "jobs"}, {"steps", "jobs"}, {"step", "jobs"}, {"recurring", "jobs"}, {"concurrency", "jobs"}, {"payload", "jobs"},
      {"translation", "translations"}, {"mail", "mail"}, {"upload", "uploads"},
    ]

    # Each page's title, in the order of the docs index.
    PAGE_TITLES = {
      "operations" => "Operations and routing", "input" => "Input", "core-types" => "Core types",
      "openapi" => "JSON endpoints and OpenAPI", "persistence" => "Persistence", "migrations" => "Migrations",
      "queries" => "Queries", "models" => "Domain models", "json-schema" => "JSON Schema", "views" => "Views and pages",
      "assets" => "Assets", "translations" => "Translations", "events" => "Domain events", "jobs" => "Background jobs",
      "mail" => "Mail", "cache" => "Cache", "auth" => "Authentication", "authorization" => "Authorization",
      "credentials" => "Credentials", "rate-limits" => "Rate limits", "uploads" => "Uploads",
    }

    record Page, path : String, sources : String, text : String | Problem

    # The pages whose sources the repository has.
    def self.pages : Array(Page)
      pages = [] of Page
      pages << Page.new("docs/reference/compile-errors.md", "spec/core/compile_errors_spec.cr and spec/fail/", compile_errors) if File.exists?(COMPILE_ERRORS)
      pages << Page.new("docs/reference/lint-rules.md", "src/punch/ameba/", lint_rules) if Dir.exists?("src/punch/ameba")
      pages << Page.new("docs/reference/check-steps.md", "the step table in src/punch/cli/tool/check.cr", check_steps) if File.exists?(CHECK)
      pages
    end

    CHECK = "src/punch/cli/tool/check.cr"

    private def self.compile_errors : String | Problem
      grouped = Hash(String, Array({String, String})).new { |hash, key| hash[key] = [] of {String, String} }
      DocsCheck.compile_errors.each do |name, message|
        topic = TOPICS.find { |prefix, _| name == prefix || name.starts_with?("#{prefix}_") }
        return Problem.new(COMPILE_ERRORS, 1, "The fixture #{name} fits no topic: add its prefix to Punch::DocsCheck::Generated::TOPICS.") unless topic

        grouped[topic[1]] << {name, message}
      end
      String.build do |io|
        io << "# Compile errors\n\n"
        io << HEADER % "spec/core/compile_errors_spec.cr and spec/fail/" << "\n\n"
        io << "What Punch's compile-time checks say, by topic. The message is the start of what the compiler prints; " \
              "the rest of it names the fix and the page that explains it. Each example is the smallest program that gives it. " \
              "How to read them, and the fixes that keep the guarantee: [When the Compiler Says No](../guides/when-the-compiler-says-no.md).\n"
        PAGE_TITLES.each do |page, title|
          entries = grouped[page]? || next
          io << "\n## " << title << "\n\n"
          io << "Explained in [" << title << "](../" << page << ".md).\n\n"
          io << "| Message | Example |\n|---|---|\n"
          entries.each { |name, message| io << "| " << code(message) << " | [" << name << "](../../spec/fail/" << name << ".cr) |\n" }
        end
      end
    end

    private def self.lint_rules : String | Problem
      rules = Dir.glob("src/punch/ameba/*.cr").sort!.compact_map { |path| LintRule.read(path) }
      String.build do |io|
        io << "# Lint rules\n\n"
        io << HEADER % "src/punch/ameba/" << "\n\n"
        io << "Punch's own Ameba rules, which `punch check` runs (its `lint` step). Each reports code that compiles but breaks a convention the docs explain. " \
              "A rule is turned off for one line only with `# ameba:disable Punch/<Rule>` and a comment saying why.\n"
        rules.each do |rule|
          io << "\n## Punch/" << rule.name << "\n\n" << rule.summary << "\n"
          rule.messages.each { |message| io << "\n- " << code(message) }
          io << "\n" unless rule.messages.empty?
        end
      end
    end

    private def self.check_steps : String | Problem
      source = File.read(CHECK)
      rows = source.lines.select(&.starts_with?("  # |")).map(&.lchop("  # "))
      return Problem.new(CHECK, 1, "The step table at the top of the file is gone.") if rows.size < 3

      String.build do |io|
        io << "# `punch check` steps\n\n"
        io << HEADER % "the step table in src/punch/cli/tool/check.cr" << "\n\n"
        io << "`punch check` runs every step that applies to the project, in this order, and runs all of them even after one fails, " \
              "so one run reports everything. `--json` gives each step's name, status (`passed`, `failed`, `skipped`), seconds, and detail.\n\n"
        rows.each { |row| io << row << "\n" }
      end
    end

    # *text* as a code span, whatever backticks or pipes it holds.
    private def self.code(text : String) : String
      text = text.gsub('|', "\\|")
      text.includes?('`') ? "`` #{text} ``" : "`#{text}`"
    end

    # A rule class's name, its doc comment's first paragraph, and the
    # messages it reports.
    record LintRule, name : String, summary : String, messages : Array(String) do
      def self.read(path : String) : self?
        source = File.read(path)
        lines = source.lines
        root = Crystal::Parser.parse(source)
        rule = find(root) || return
        start = rule.location.try(&.line_number) || return
        comment = [] of String
        index = start - 2
        while index >= 0 && lines[index].lstrip.starts_with?('#')
          comment.unshift(lines[index].lstrip.lchop('#').lstrip)
          index -= 1
        end
        summary = comment.take_while { |line| !line.blank? && !line.starts_with?("```") }.join(' ')
        messages = [] of String
        collect(rule.body, messages)
        new(rule.name.names.last, summary, messages)
      end

      private def self.find(node : Crystal::ASTNode) : Crystal::ClassDef?
        case node
        when Crystal::Expressions then node.expressions.each { |child| find(child).try { |found| return found } }
        when Crystal::ModuleDef   then find(node.body)
        when Crystal::ClassDef    then node
        end
      end

      private def self.collect(node : Crystal::ASTNode, messages : Array(String)) : Nil
        case node
        when Crystal::Expressions then node.expressions.each { |child| collect(child, messages) }
        when Crystal::Assign
          target, value = node.target, node.value
          messages << value.value if target.is_a?(Crystal::Path) && target.names.last.starts_with?("MSG") && value.is_a?(Crystal::StringLiteral)
        end
      end
    end
  end
end
