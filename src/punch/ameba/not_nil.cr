module Ameba::Rule::Punch
  # Keeps `nil` a value the compiler checks (docs/guides/crystal-for-punch-developers.md):
  # hand-written code under `app/` does not call `not_nil!`, which turns a
  # compile error into a crash at run time. Handle the `nil` first, with a
  # result such as `NotFound` or `|| return`, and the compiler knows the
  # value is there after that line.
  #
  # ```
  # Punch/NotNil:
  #   Enabled: true
  # ```
  class NotNil < Base
    properties do
      since_version "1.7.0"
      description "Reports not_nil! in app code"
    end

    MSG = "Handle the `nil` instead of `not_nil!`: return a result (`|| return NotFound.new`), and the compiler knows the value is there after that line (lib/punch/docs/guides/crystal-for-punch-developers.md)"

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.calls.each { |node| issue_for node, MSG }
    end

    private class Finder < Crystal::Visitor
      getter calls = [] of Crystal::Call

      def visit(node : Crystal::Call)
        calls << node if node.name == "not_nil!"
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
