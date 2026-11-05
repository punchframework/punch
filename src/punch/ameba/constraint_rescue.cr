module Ameba::Rule::Punch
  # Keeps constraint violations values: hand-written code under `app/` does
  # not rescue `Punch::Database::ConstraintError`. A unique violation is
  # returned by the generated write that can cause it, as a type in its
  # result; any other constraint failure (a foreign key, a `CHECK`) means a
  # check the Command should have made, which is a bug. Generated files are
  # skipped.
  #
  # ```
  # Punch/ConstraintRescue:
  #   Enabled: true
  # ```
  class ConstraintRescue < Base
    properties do
      since_version "1.7.0"
      description "Reports rescuing ConstraintError in app code"
    end

    MSG = "Do not rescue ConstraintError: a generated write returns unique violations as values (`in EmailTaken`), and other constraints are checked in the Command first (lib/punch/docs/queries.md#violations)"

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.paths.each { |node| issue_for node, MSG }
    end

    private class Finder < Crystal::Visitor
      getter paths = [] of Crystal::Path

      def visit(node : Crystal::Rescue)
        node.types.try &.each do |type|
          paths << type if type.is_a?(Crystal::Path) && type.names.last == "ConstraintError"
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
