module Ameba::Rule::Punch
  # Keeps unescaped markup visible in review: the argument of
  # `SafeHTML.trusted` is a string literal, written by the programmer, so
  # nothing from a request, the database, or a file can reach a page
  # unescaped. Markup built at run time is built with the view's elements,
  # which escape. A real exception says why, with
  # `# ameba:disable Punch/TrustedHTML` on the line before.
  #
  # Reported:
  #
  # - a call named `trusted` with anything but one string literal, on any
  #   receiver (an alias or a variable holding `SafeHTML` is still
  #   `SafeHTML`), also inside macros, where each `{{ … }}` counts as a
  #   value;
  # - reopening `SafeHTML` outside Punch, which could add a constructor
  #   that takes any string;
  # - a `text/html` content type written outside Punch and its specs: a
  #   response built by hand with it (`HTTP::Response.new(:ok, body,
  #   headers)`) sends whatever the string holds, where `Response.html`
  #   and pages take only `SafeHTML`.
  #
  # ```
  # Punch/TrustedHTML:
  #   Enabled: true
  # ```
  class TrustedHTML < Base
    properties do
      since_version "1.7.0"
      description "Reports SafeHTML.trusted with anything but a string literal"
    end

    MSG          = "`SafeHTML.trusted` takes a string literal; build markup from data with the view's elements, which escape (lib/punch/docs/views.md)"
    MSG_REOPEN   = "Reopening `SafeHTML` can make markup from any string: build markup with the view's elements, which escape (lib/punch/docs/views.md)"
    MSG_RESPONSE = "A `text/html` response built by hand sends the string unescaped: answer with a page, or `Response.html`, which takes a `SafeHTML` (lib/punch/docs/views.md)"

    def test(source : Source)
      visitor = Finder.new(source.path)
      source.ast.accept(visitor)
      visitor.issues.each { |node, message| issue_for node, message }
    end

    private class Finder < Crystal::Visitor
      getter issues = [] of {Crystal::ASTNode, String}

      def initialize(@path : String)
      end

      def visit(node : Crystal::Call)
        issues << {node, MSG} if node.name == "trusted" && !(node.args.size == 1 && node.named_args.nil? && literal?(node.args.first))
        true
      end

      def visit(node : Crystal::ClassDef)
        issues << {node, MSG_REOPEN} if node.name.names.last == "SafeHTML" && !punch?
        true
      end

      def visit(node : Crystal::StringLiteral)
        issues << {node, MSG_RESPONSE} if node.value.downcase.starts_with?("text/html") && !punch? && !spec?
        true
      end

      def visit(node : Crystal::Macro | Crystal::MacroIf | Crystal::MacroFor | Crystal::MacroVerbatim)
        if code = MacroCode.parse(node, @path)
          inner = Finder.new(@path)
          code.accept(inner)
          issues.concat(inner.issues)
        elsif MacroCode.render(node).includes?(".trusted")
          issues << {node, MSG}
        end
        false
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      # Punch's own code, whose responses and views set `text/html`.
      private def punch? : Bool
        @path.starts_with?("src/punch/") || @path.includes?("/src/punch/")
      end

      # Specs and their helpers, which send `Accept: text/html`.
      private def spec? : Bool
        @path.ends_with?("_spec.cr") || File.basename(@path) == "spec_helper.cr" || @path.includes?("spec/support/")
      end

      # A string literal, or a heredoc, which parses as an interpolation of
      # literal pieces.
      private def literal?(node : Crystal::ASTNode) : Bool
        node.is_a?(Crystal::StringLiteral) ||
          (node.is_a?(Crystal::StringInterpolation) && node.expressions.all?(Crystal::StringLiteral))
      end
    end
  end
end
