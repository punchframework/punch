module Ameba::Rule::Punch
  # Keeps database handles out of models: a model decides, an operation
  # orchestrates. In app code (files under `app/`), `Punch::Reader`,
  # `Punch::Writer`, `Punch::Database`, and `Punch::Databases` appear only
  # inside an operation (a subclass of `Command`, `Query`, or `Page`) and
  # inside a store (a type named `Store` or ending in `Store`), which loads
  # and saves models with the generated queries, inside the app's actor (a
  # type that includes `Punch::Auth::Actor`), whose `load` runs in the
  # operation's transaction (docs/auth.md), and inside a policy (a type that
  # includes `Punch::Policy`), which decides in it (docs/authorization.md),
  # and inside an inbound webhook provider (a subclass of `Inbound`), whose
  # `process` writes like a Command (docs/webhooks.md), and inside a
  # subscriber (a type that includes `Punch::Subscriber(Event)`), whose
  # inline `call` writes in the Command's transaction (docs/events.md).
  # Generated files are skipped.
  #
  # ```
  # Punch/ModelDatabase:
  #   Enabled: true
  # ```
  class ModelDatabase < Base
    properties do
      since_version "1.7.0"
      description "Reports database handles in app code outside operations and stores"
    end

    HANDLES = %w[Punch::Reader Punch::Writer Punch::Database Punch::Databases]

    MSG = "`%s` outside an operation or a store: models never take a database handle; load and save in the operation or a Store (lib/punch/docs/models.md)"

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.paths.each { |node| issue_for node, MSG % node.names.join("::") }
    end

    private class Finder < Crystal::Visitor
      getter paths = [] of Crystal::Path
      # How many enclosing definitions may use handles.
      @allowed = 0

      def visit(node : Crystal::Path)
        paths << node if @allowed == 0 && HANDLES.includes?(node.names.join("::"))
        true
      end

      def visit(node : Crystal::ClassDef)
        @allowed += 1 if allows?(node)
        true
      end

      def end_visit(node : Crystal::ClassDef)
        @allowed -= 1 if allows?(node)
      end

      def visit(node : Crystal::ModuleDef)
        @allowed += 1 if allows?(node.name)
        true
      end

      def end_visit(node : Crystal::ModuleDef)
        @allowed -= 1 if allows?(node.name)
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      private def allows?(node : Crystal::ClassDef) : Bool
        allows?(node.name) || Operations.operation?(node) || Operations.provider?(node) ||
          includes?(node, %w[Punch Auth Actor]) || includes?(node, %w[Punch Policy]) || subscriber?(node)
      end

      # Whether *node* includes `Punch::Subscriber(Event)`.
      private def subscriber?(node : Crystal::ClassDef) : Bool
        body = node.body
        expressions = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        expressions.any? do |expression|
          expression.is_a?(Crystal::Include) && (name = expression.name).is_a?(Crystal::Generic) &&
            (path = name.name).is_a?(Crystal::Path) && path.names == %w[Punch Subscriber]
        end
      end

      private def allows?(name : Crystal::Path) : Bool
        name.names.last.ends_with?("Store")
      end

      private def includes?(node : Crystal::ClassDef, mod : Array(String)) : Bool
        body = node.body
        expressions = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        expressions.any? do |expression|
          expression.is_a?(Crystal::Include) && (name = expression.name).is_a?(Crystal::Path) && name.names == mod
        end
      end
    end
  end

  # :nodoc:
  module Operations
    # Hand-written app code: files under `app/`, generated ones excluded.
    # The Punch repository's own `Command` classes (the CLI) are not
    # operations and live under `src/`.
    def self.app_code?(path : String) : Bool
      (path.starts_with?("app/") || path.includes?("/app/")) && !path.ends_with?(".gen.cr")
    end

    # Whether *node* defines an operation: its superclass is `Command`,
    # `Query`, or `Page`, qualified or not.
    def self.operation?(node : Crystal::ClassDef) : Bool
      superclass = node.superclass
      superclass.is_a?(Crystal::Path) && superclass.names.last.in?("Command", "Query", "Page")
    end

    # Whether *node* defines an inbound webhook provider: its superclass is
    # `Punch::Webhook::Inbound`.
    def self.provider?(node : Crystal::ClassDef) : Bool
      superclass = node.superclass
      superclass.is_a?(Crystal::Path) && superclass.names.last(2) == %w[Webhook Inbound]
    end
  end
end
