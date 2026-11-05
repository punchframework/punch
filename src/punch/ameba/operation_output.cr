module Ameba::Rule::Punch
  # Names what an operation answers: a Query, Command, or Page declares
  # `alias Output = …`, the union of everything its `call` can return, right
  # above `call`, and `call` returns `: Output`. The operation's answers are
  # then one line to read, the same in every operation, and the name pages
  # and specs use (`Send::Output`). Applies to app code (files under
  # `app/`); Punch derives the contract from whatever `call` declares, so
  # this is a convention, not a compile error (docs/operations.md).
  #
  # ```
  # Punch/OperationOutput:
  #   Enabled: true
  # ```
  class OperationOutput < Base
    properties do
      since_version "1.7.0"
      description "Reports an operation whose call does not return its declared Output"
    end

    MSG_ALIAS  = "`%s` declares what `call` returns as `alias Output = A | B`, above `call` (lib/punch/docs/operations.md)"
    MSG_RETURN = "`%s#call` returns `: Output`, the operation's declared alias (lib/punch/docs/operations.md)"

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.found.each { |node, message| issue_for node, message }
    end

    private class Finder < Crystal::Visitor
      getter found = [] of {Crystal::ASTNode, String}

      def visit(node : Crystal::ClassDef)
        return true unless Operations.operation?(node)

        body = node.body
        members = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        call = members.find { |member| member.is_a?(Crystal::Def) && member.name == "call" }.as?(Crystal::Def)
        return true unless call

        name = node.name.names.join("::")
        unless members.any? { |member| member.is_a?(Crystal::Alias) && member.name.names == ["Output"] }
          found << {node.as(Crystal::ASTNode), MSG_ALIAS % name}
        end
        returned = call.return_type
        unless returned.is_a?(Crystal::Path) && returned.names == ["Output"]
          found << {call.as(Crystal::ASTNode), MSG_RETURN % name}
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
