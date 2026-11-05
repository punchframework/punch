require "../cli"
require "../query_gen"
require "./tool/openapi"
require "./tool/jobs_lock"
require "./tool/routes"
require "./tool/events"
require "./tool/dev"
require "./tool/dev_rounds"
require "./tool/bareknuckle_build"
require "./tool/typecheck"
require "./tool/check"
require "./tool/db_cost"
require "./tool/db_explain"
require "./tool/i18n"
require "./tool/requires"
require "./tool/authz"
require "./tool/forward"
require "./tool/handshake"
require "./tool/db_seed"
require "./tool/new"
require "./tool/generate"
require "./tool/upgrade"
require "./tool/docs_check"
require "./tool/tool_install"

module Punch::CLI
  module Commands
    # Writes the typed Crystal for the app's schema and named queries. With
    # `--check`, writes nothing and fails when a committed file differs from
    # what it would write, for CI.
    class DbGenerate < Command
      command "db:generate", "Generate typed Crystal from db/schema.sql, the columns.cr files, and the .sql files in app/ and src/; --check compares instead"

      struct Result
        include Report

        def initialize(@states : Array({String, String}), @result : QueryGen::Result)
        end

        def to_text(io : IO) : Nil
          @states.each { |path, state| io.puts "#{state.ljust(9)} #{path}" }
          analyses = @result.analyses
          annotated = analyses.count { |analysis| analysis.columns.any?(&.source.annotation?) || analysis.params.any?(&.source.annotation?) }
          mapped = @result.schema.tables.values.select(&.mod)
          behaviour = mapped.count { |table| table.behaviour.try { |path| File.exists?(path) } }
          violations = mapped.sum { |table| emitted(table).size }
          io.puts "#{analyses.size} queries (#{annotated} with annotations), #{mapped.size} mapped tables (#{behaviour} with behaviour), #{violations} violation types."
        end

        def to_json(json : JSON::Builder) : Nil
          json.object do
            json.field "files" do
              json.array { @states.each { |path, state| json.object { json.field "path", path; json.field "state", state } } }
            end
            json.field "queries" do
              json.array { @result.analyses.each { |analysis| query_json(json, analysis) } }
            end
            json.field "tables" do
              json.array do
                @result.schema.tables.each_value.select(&.mod).each do |table|
                  json.object do
                    json.field "name", table.name
                    json.field "module", table.mod
                    json.field "behaviour", table.behaviour
                    json.field "behaviour_exists", table.behaviour.try { |path| File.exists?(path) } || false
                    json.field "violations" do
                      json.array do
                        emitted(table).each do |unique|
                          json.object do
                            json.field "type", "#{table.mod}::#{unique.type_name}"
                            json.field "constraint", unique.constraint(table.name)
                            json.field "index", unique.name
                            json.field "field", unique.field
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end

        # The violation types written for *table*: a rowid's only where a
        # query can violate it.
        private def emitted(table : QueryGen::Schema::Table) : Array(QueryGen::Schema::Unique)
          used = @result.analyses.flat_map(&.violations)
          table.uniques.reject { |unique| unique.rowid? && !used.includes?(unique) }
        end

        private def query_json(json : JSON::Builder, analysis : QueryGen::Analysis) : Nil
          query = analysis.query
          json.object do
            json.field "name", query.name
            json.field "location", query.location.to_s
            json.field "kind", query.kind.to_s.underscore.delete('_')
            json.field "returns", analysis.record.try(&.mod).try { |mod| "#{mod}::Record" } || (analysis.columns.empty? ? nil : "#{query.name}::Row")
            json.field "columns" { types_json(json, analysis.columns.map { |column| {column.name, column.type, column.source} }) }
            json.field "params" { types_json(json, analysis.params.map { |param| {param.name, param.type, param.source} }) }
            json.field "includes", query.includes.map(&.[0])
            json.field "violations", analysis.violations.map { |unique| "#{analysis.target.try(&.mod)}::#{unique.type_name}" }
            analysis.filtered.try { |filtered| clauses_json(json, filtered) }
          end
        end

        # A query's declared clauses: each filter field with its type, the
        # orders (the first is the default), and the statements prepared.
        private def clauses_json(json : JSON::Builder, filtered : QueryGen::Filtered) : Nil
          json.field "filter" do
            json.array do
              filtered.fields.each do |field|
                json.object do
                  json.field "name", field.clause.key
                  json.field "type", field.type
                  json.field "members", field.members.compact_map(&.member) if field.enum_type
                  json.field "location", field.clause.location.to_s
                end
              end
            end
          end
          json.field "orders", filtered.orders.map(&.key)
          json.field "variants", filtered.variants.size
          filtered.keyset.try { |keyset| keyset_json(json, keyset) }
        end

        # A `:page` query's keyset: per order, the sort columns the cursor
        # carries and the condition after it.
        private def keyset_json(json : JSON::Builder, keyset : QueryGen::Keyset) : Nil
          json.field "pages" do
            json.array do
              keyset.keys.each do |key|
                json.object do
                  json.field "order", key.order.try(&.key)
                  json.field "direction", key.order.try { |order| order.reversed? ? "desc" : "asc" }
                  json.field "cursor", key.terms.map(&.column.name)
                  json.field "after", key.sql
                end
              end
            end
          end
        end

        private def types_json(json : JSON::Builder, entries : Array({String, QueryGen::Type, QueryGen::Source})) : Nil
          json.array do
            entries.each do |name, type, source|
              json.object do
                json.field "name", name
                json.field "type", type.crystal
                json.field "source", source.to_s.underscore
              end
            end
          end
        end
      end

      def run(args : Array(String)) : Report | Failure
        check = args.delete("--check")
        if option = args.find(&.starts_with?("-"))
          return Failure.usage("unexpected_argument", "'punch db:generate' takes query files and --check, not '#{option}'.")
        end
        unless File.exists?(Punch::Migrations::SCHEMA)
          if File.exists?(QueryGen::Composites::OWN_PATH)
            result = QueryGen.own_composites
            return check ? compare(result) : write(result)
          end
          return Failure.new("missing_schema", "#{Punch::Migrations::SCHEMA} does not exist. Run 'punch db:migrate' first; the generator reads the schema file.")
        end
        if missing = args.find { |path| !File.exists?(path) }
          return Failure.new("missing_file", "#{missing} does not exist.")
        end

        queries = args.empty? ? QueryGen.query_files : args
        result = QueryGen.run(QueryGen::Config.new(queries: queries, app_dir: QueryGen.app_dir))
        check ? compare(result) : write(result)
      rescue ex : QueryGen::Errors
        Failure.new("generate_failed", ex.message || "generation failed")
      end

      private def write(result : QueryGen::Result) : Report
        states = result.outputs.map do |output|
          current = File.exists?(output.path) ? File.read(output.path) : nil
          next {output.path, "unchanged"} if current == output.content
          Dir.mkdir_p(File.dirname(output.path))
          File.write(output.path, output.content)
          {output.path, "written"}
        end
        Result.new(states, result)
      end

      private def compare(result : QueryGen::Result) : Report | Failure
        stale = result.outputs.compact_map do |output|
          output.path unless File.exists?(output.path) && File.read(output.path) == output.content
        end
        return Result.new(result.outputs.map { |output| {output.path, "current"} }, result) if stale.empty?

        Failure.new("stale_generated_files", "#{stale.join(", ")} #{stale.size == 1 ? "does" : "do"} not match the schema and queries. Run 'punch db:generate' and commit the result; never edit generated files by hand.")
      end
    end
  end

  # The commands of the standalone `punch` binary: everything an application
  # binary has, `routes` and `events` by building the app, plus the generator and the
  # tools that build the app, which applications do not compile in.
  TOOL_COMMANDS = COMMANDS + [Commands::ToolRoutes, Commands::ToolEvents, Commands::DbGenerate, Commands::DbSeed, Commands::DbCost, Commands::DbExplain, Commands::ToolAuthzExplain, Commands::OpenAPIWrite, Commands::OpenAPIDiff, Commands::JobsLock, Commands::I18nGenerate, Commands::RequiresGenerate,
                              Commands::Dev, Commands::DevRounds, Commands::BareknuckleBuild, Commands::Check, Commands::Typecheck, Commands::New, Commands::Generate, Commands::TemplateRender, Commands::UpgradeDiff, Commands::ToolInstall, Commands::DocsCheck] of Command.class
end
