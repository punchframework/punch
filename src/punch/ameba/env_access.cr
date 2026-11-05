module Ameba::Rule::Punch
  # Keeps app settings and secrets in the declared credentials: hand-written
  # code under `app/` does not read `ENV`, nor the process environment
  # through `LibC.getenv`. A value read there would be unchecked at boot,
  # invisible to `creds:check`, and a plain `String` instead of a
  # `Punch::Secret`.
  #
  # ```
  # Punch/EnvAccess:
  #   Enabled: true
  # ```
  class EnvAccess < Base
    properties do
      since_version "1.7.0"
      description "Reports ENV in app code"
    end

    MSG = "Declare this setting in the app's credentials type (Punch::Credentials) instead of reading ENV (lib/punch/docs/credentials.md)"

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.paths.each { |node| issue_for node, MSG }
    end

    private class Finder < Crystal::Visitor
      getter paths = [] of Crystal::Path

      def visit(node : Crystal::Path)
        paths << node if node.names == ["ENV"]
        true
      end

      def visit(node : Crystal::Call)
        receiver = node.obj
        paths << receiver if node.name == "getenv" && receiver.is_a?(Crystal::Path) && receiver.names.last == "LibC"
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
