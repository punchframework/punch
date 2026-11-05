module Punch::CLI::Commands
  # `EXPLAIN QUERY PLAN` over every statement of the app's named queries:
  # each query as written, and every variant its declared clauses and pages
  # give. Shows each query's findings, a scan of a whole table or a sort of
  # what was read; `--all` shows every plan. With `--check`, fails on a
  # finding the query's header does not accept.
  class DbExplain < Command
    command "db:explain", "Show the query plan of every named query and flag full scans and sorts; --check fails on one the query does not accept (-- scan: or -- sort: with a reason), --all prints every plan"

    struct Result
      include Report

      def initialize(@reports : Array(QueryGen::Explain::Report), @all : Bool)
      end

      def to_text(io : IO) : Nil
        statements = @reports.sum(&.plans.size)
        found = @reports.reject(&.findings.empty?)
        accepted = found.count(&.problems.empty?)
        io << @reports.size << " queries, " << statements << " statements: "
        io << (found.empty? ? "no full scans or sorts" : "#{found.size} with a full scan or sort (#{accepted} accepted)") << '\n'
        @reports.each do |report|
          next if !@all && report.findings.empty?
          query = report.query
          io << query.location << ' ' << query.name << '\n'
          report.findings.each do |finding, label|
            reason = query.accepted[finding.kind]?.try { |entry| "accepted: #{entry[0]}" } || "not accepted"
            io << "  " << finding.kind << "  " << finding.text << (label == "as written" ? "" : " (#{label})") << "; " << reason << '\n'
          end
          next unless @all
          report.plans.each do |plan|
            io << "  [" << plan.label << "]\n"
            plan.steps.each { |step| io << "    " << "  " * step.depth << step.detail << '\n' }
          end
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "queries" do
            json.array { @reports.each { |report| report_json(json, report) } }
          end
        end
      end

      private def report_json(json : JSON::Builder, report : QueryGen::Explain::Report) : Nil
        json.object do
          json.field "name", report.query.name
          json.field "location", report.query.location.to_s
          json.field "accepted", report.query.accepted.transform_values(&.[0])
          json.field "problems", report.problems
          json.field "statements" do
            json.array do
              report.plans.each do |plan|
                json.object do
                  json.field "label", plan.label
                  json.field "sql", plan.sql
                  json.field "plan" { json.array { plan.steps.each { |step| json.object { json.field "depth", step.depth; json.field "detail", step.detail } } } }
                  json.field "findings" { json.array { plan.findings.each { |finding| json.object { json.field "kind", finding.kind; json.field "text", finding.text } } } }
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      check = !!args.delete("--check")
      all = !!args.delete("--all")
      if failure = no_arguments(args)
        return failure
      end
      unless File.exists?(Punch::Migrations::SCHEMA)
        return Failure.new("missing_schema", "#{Punch::Migrations::SCHEMA} does not exist. Run 'punch db:migrate' first; the plans come from the schema file.")
      end

      result = QueryGen.run(QueryGen::Config.new(queries: QueryGen.query_files, app_dir: QueryGen.app_dir, explain: true))
      report = Result.new(result.plans, all)
      problems = result.plans.flat_map(&.problems)
      return report if !check || problems.empty?

      Failure.new("unaccepted_plan", problems.join("\n"), details: JSON.parse(report.to_json))
    rescue ex : QueryGen::Errors
      Failure.new("generate_failed", ex.message || "generation failed")
    end
  end
end
