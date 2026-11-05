module Ameba::Rule::Punch
  # Keeps status checks out of operations. An entity whose state decides
  # what may happen to it has a type per state, and an operation branches on
  # those types (`case invoice in Invoice::Sent`), so adding a state breaks
  # every place that must handle it. Comparing a status
  # (`invoice.status == …`, `row.status.sent?`, `case row.status`) inside a
  # `Command`, `Query`, or `Page` subclass in app code (under `app/`) is
  # reported. For an entity without state types, a status check showing up
  # in an operation is the sign to give it some (docs/models.md); until
  # then, disable the rule on that line.
  #
  # ```
  # Punch/StatusComparison:
  #   Enabled: true
  #   StatusMethods: [status]
  # ```
  class StatusComparison < Base
    properties do
      since_version "1.7.0"
      description "Reports status comparisons inside operations"
      status_methods ["status"]
    end

    MSG = "Compares `%s` in an operation: branch on the state types instead (`case invoice in Invoice::Sent`) (lib/punch/docs/models.md)"

    COMPARISONS = %w[== != === in? includes?]

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new(status_methods)
      source.ast.accept(visitor)
      visitor.found.each { |node, status| issue_for node, MSG % status }
    end

    private class Finder < Crystal::Visitor
      getter found = [] of {Crystal::ASTNode, String}
      @operations = 0

      def initialize(@methods : Array(String))
      end

      def visit(node : Crystal::ClassDef)
        @operations += 1 if Operations.operation?(node)
        true
      end

      def end_visit(node : Crystal::ClassDef)
        @operations -= 1 if Operations.operation?(node)
      end

      def visit(node : Crystal::Call)
        return true if @operations == 0

        if (receiver = node.obj) && status?(receiver) && (COMPARISONS.includes?(node.name) || predicate?(node.name))
          found << {node, describe(receiver)}
        elsif COMPARISONS.includes?(node.name) && (argument = node.args.find { |arg| status?(arg) })
          found << {node, describe(argument)}
        end
        true
      end

      def visit(node : Crystal::Case)
        if @operations > 0 && (condition = node.cond) && status?(condition)
          found << {node, describe(condition)}
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      # `x.status`: a call of a status method on something.
      private def status?(node : Crystal::ASTNode) : Bool
        node.is_a?(Crystal::Call) && !node.obj.nil? && node.args.empty? && @methods.includes?(node.name)
      end

      # `&.status` reads as `__arg0.status` in the tree.
      private def describe(node : Crystal::ASTNode) : String
        text = node.to_s
        text.starts_with?("__arg") ? "&.#{text.partition('.').last}" : text
      end

      private def predicate?(name : String) : Bool
        name.ends_with?('?') && name != "nil?"
      end
    end
  end
end
