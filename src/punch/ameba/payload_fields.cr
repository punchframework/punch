module Ameba::Rule::Punch
  # Keeps stored payloads to IDs and small values (docs/jobs.md): a field of
  # a job or an event (a `record` or type that includes `Punch::Job` or
  # `Punch::Event`) is not a collection: `Array`, `Hash`, `Set`, `Deque`,
  # `Tuple`, `NamedTuple`, `Bytes` or `Slice`, or `JSON::Any`. Every payload
  # is a row in the outbox and the queue, read again on every attempt; a
  # list in it grows with the data, and the job then runs on a copy as it
  # was when enqueued. Store the IDs that find the rows, and read them when
  # the job runs. (A whole record in a payload does not compile.) A job that
  # really carries a short list says why, with
  # `# ameba:disable Punch/PayloadFields`.
  #
  # ```
  # Punch/PayloadFields:
  #   Enabled: true
  # ```
  class PayloadFields < Base
    properties do
      since_version "1.7.0"
      description "Reports collections in job and event payloads"
    end

    MSG = "`%s` holds a collection in a stored payload: store the IDs that find the rows and read them when the job runs, so the payload stays small (lib/punch/docs/jobs.md)"

    COLLECTIONS = %w[Array Hash Set Deque Tuple NamedTuple Bytes Slice StaticArray]
    PAYLOADS    = [%w[Punch Job], %w[Punch Job Stepped], %w[Punch Event]]

    def test(source : Source)
      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.fields.each { |node, name| issue_for node, MSG % name }
    end

    private class Finder < Crystal::Visitor
      getter fields = [] of {Crystal::ASTNode, String}

      # `record Name, field : Type do include Punch::Job end`.
      def visit(node : Crystal::Call)
        block = node.block
        if node.name == "record" && node.obj.nil? && block && payload?(block.body)
          node.args.each { |arg| check(arg) }
        end
        true
      end

      # A struct or class whose body includes `Punch::Job` or `Punch::Event`.
      def visit(node : Crystal::ClassDef)
        return true unless payload?(node.body)

        each_statement(node.body) do |statement|
          case statement
          when Crystal::TypeDeclaration then check(statement)
          when Crystal::Call
            statement.args.each { |arg| check(arg) } if statement.obj.nil? && statement.name.in?("getter", "property")
          end
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      private def check(node : Crystal::ASTNode) : Nil
        node = node.target if node.is_a?(Crystal::Assign)
        return unless node.is_a?(Crystal::TypeDeclaration)

        fields << {node, node.var.to_s} if collection?(node.declared_type)
      end

      private def collection?(type : Crystal::ASTNode) : Bool
        case type
        when Crystal::Path    then type.names.last.in?(COLLECTIONS) || type.names.last(2) == %w[JSON Any]
        when Crystal::Generic then collection?(type.name) || type.type_vars.any? { |var| collection?(var) }
        when Crystal::Union   then type.types.any? { |member| collection?(member) }
        else                       false
        end
      end

      private def payload?(body : Crystal::ASTNode) : Bool
        found = false
        each_statement(body) do |statement|
          next unless statement.is_a?(Crystal::Include)

          name = statement.name
          name = name.name if name.is_a?(Crystal::Generic)
          found = true if name.is_a?(Crystal::Path) && name.names.in?(PAYLOADS)
        end
        found
      end

      private def each_statement(body : Crystal::ASTNode, & : Crystal::ASTNode ->) : Nil
        if body.is_a?(Crystal::Expressions)
          body.expressions.each { |statement| yield statement }
        else
          yield body
        end
      end
    end
  end
end
