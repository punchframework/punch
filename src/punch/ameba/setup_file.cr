module Ameba::Rule::Punch
  # Keeps app-wide declarations where people and agents look for them
  # (docs/structure.md): `Punch.assets`, `Punch.translations`,
  # `Punch.migrations`, `Punch.credentials`, a console's `mount`, and every
  # `Punch::….config =` in `app/setup.cr`; `Punch.table` in a `columns.cr`,
  # the only files `punch db:generate` reads. Checks statements at the top
  # level and in module bodies of files under `app/`, not code in methods.
  #
  # ```
  # Punch/SetupFile:
  #   Enabled: true
  # ```
  class SetupFile < Base
    properties do
      since_version "1.7.0"
      description "Reports app-wide Punch declarations outside app/setup.cr, and Punch.table outside a columns.cr"
    end

    SETUP    = "`%s` configures the whole app: put it in `app/setup.cr`, with every Punch declaration (lib/punch/docs/structure.md)"
    COLUMNS  = "`Punch.table` is read by `punch db:generate` only from `columns.cr`: put it in the `columns.cr` of the entity that owns the table (lib/punch/docs/queries.md)"
    DECLARED = %w[assets translations migrations credentials]

    def test(source : Source)
      path = source.path
      return unless path.starts_with?("app/") || path.includes?("/app/")

      setup = path == "app/setup.cr" || path.ends_with?("/app/setup.cr")
      columns = File.basename(path) == "columns.cr"
      statements(source.ast).each do |node|
        next unless node.is_a?(Crystal::Call)
        message = misplaced(node, setup, columns)
        issue_for node, message if message
      end
    end

    # Why *call* is in the wrong file, or `nil`.
    private def misplaced(call : Crystal::Call, setup : Bool, columns : Bool) : String?
      obj = call.obj
      return unless obj.is_a?(Crystal::Path) && obj.names.first == "Punch"

      top = obj.names.size == 1
      return (columns ? nil : COLUMNS) if top && call.name == "table"
      return if setup

      SETUP % "#{obj}.#{call.name}" if call.name.ends_with?('=') || call.name == "mount" || (top && DECLARED.includes?(call.name))
    end

    # Top-level statements and those in module bodies, recursively.
    private def statements(node : Crystal::ASTNode) : Array(Crystal::ASTNode)
      case node
      when Crystal::Expressions then node.expressions.flat_map { |child| statements(child) }
      when Crystal::ModuleDef   then statements(node.body)
      else                           [node] of Crystal::ASTNode
      end
    end
  end
end
