module Punch::QueryGen
  # `EXPLAIN QUERY PLAN` over every statement the generator prepares: each
  # query as written, and for declared clauses and pages every variant. Two
  # kinds of step are findings: a `scan`, which reads every row of a table
  # (through an index or not), and a `sort`, a temporary B-tree for
  # `ORDER BY`, `GROUP BY`, or `DISTINCT` over what was read. A query
  # accepts a kind with a reason in its header, `-- scan: ...` or
  # `-- sort: ...`; any other finding fails `punch db:explain --check`.
  #
  # The plans come from the schema without data or statistics, as a fresh
  # database has them; `PRAGMA optimize` in production may choose others.
  module Explain
    KINDS = {"scan", "sort"}

    # One step of a plan, indented by its depth.
    record Step, depth : Int32, detail : String

    record Finding, kind : String, text : String

    # The plan of one statement of a query.
    record Plan, label : String, sql : String, steps : Array(Step), findings : Array(Finding)

    # A query's plans and what they found.
    struct Report
      getter analysis : Analysis
      getter plans : Array(Plan)

      def initialize(@analysis : Analysis, @plans : Array(Plan))
      end

      def query : Query
        @analysis.query
      end

      # The findings of every plan, each once, with the first statement
      # that has it.
      def findings : Array({Finding, String})
        seen = {} of Finding => String
        @plans.each { |plan| plan.findings.each { |finding| seen[finding] ||= plan.label } }
        seen.to_a
      end

      # Findings whose kind the query does not accept, and acceptances
      # without a finding of their kind.
      def problems : Array(String)
        found = findings
        problems = found.reject { |finding, _| query.accepted.has_key?(finding.kind) }.map do |finding, label|
          "#{query.location}: query #{query.name} #{finding.text}#{label == "as written" ? "" : " (#{label})"}. " \
          "Add an index that serves it, or say why it is fine in the header: `-- #{finding.kind}: <reason>`."
        end
        query.accepted.each do |kind, (_, location)|
          next if found.any? { |finding, _| finding.kind == kind }
          problems << "#{location}: query #{query.name}: no statement of it has a #{kind}; remove `-- #{kind}:`."
        end
        problems
      end
    end

    # *analysis*'s statements with their plans.
    def self.report(connection : Database::Driver::Connection, analysis : Analysis, schema : Schema) : Report
      plans = statements(analysis).map do |label, sql|
        steps = steps(connection.query_plan(sql))
        Plan.new(label, sql, steps, steps.compact_map { |step| finding(step.detail, schema) }.uniq!)
      end
      Report.new(analysis, plans)
    end

    # The query as written; with declared clauses, also what the generator
    # prepared and what a request most often runs: no filter or one `when`
    # at a time, with each order, and for a page after a cursor. Orders read
    # backwards are left out, since an index serves both directions.
    def self.statements(analysis : Analysis) : Array({String, String})
      filtered = analysis.filtered || return [{"as written", analysis.query.sql}]
      query = analysis.query
      list = filtered.variants.dup
      sets = [{"no filter", [] of Clause}] + query.whens.map { |clause| {"only when #{clause.label}", [clause]} }
      orders = query.orders.empty? ? [nil] : query.orders.map(&.as(Clause?))
      sets.each do |label, switched_on|
        orders.each do |order|
          switched = order ? switched_on + [order] : switched_on
          name = order ? "#{label}, order #{order.key}" : label
          list << {name, query.assemble(switched)}
          filtered.keyset.try do |keyset|
            keyset.keys.each do |key|
              next if key.order.try(&.key) != order.try(&.key) || key.order.try(&.reversed?)
              list << {"#{name}, after a cursor", keyset.assemble(query, switched, key)}
            end
          end
        end
      end
      filtered.keyset.try { |keyset| list << {"by key", keyset.assemble_by_key(query, query.whens)} }
      list.uniq(&.[1])
    end

    private def self.steps(rows : Array({Int64, Int64, String})) : Array(Step)
      depths = {0_i64 => -1}
      rows.map do |id, parent, detail|
        depth = (depths[parent]? || -1) + 1
        depths[id] = depth
        Step.new(depth, detail)
      end
    end

    # What a plan step finds: a scan of one of the schema's tables, or a
    # sort. A scan of a subquery, a CTE, or a virtual table is not one.
    def self.finding(detail : String, schema : Schema) : Finding?
      if match = detail.match(/\ASCAN (\S+)(?: AS \S+)?(?: USING (?:COVERING )?INDEX (\S+))?\z/)
        table = match[1]
        return unless schema.tables.has_key?(table)

        Finding.new("scan", match[2]?.try { |index| "reads every row of #{table} (through #{index})" } || "reads every row of #{table}")
      elsif match = detail.match(/\AUSE TEMP B-TREE FOR (ORDER BY|GROUP BY|DISTINCT)\z/)
        Finding.new("sort", "sorts every row it reads for #{match[1]}")
      end
    end
  end
end
