module Ameba::Rule::Punch
  # Keeps SQLite behind Punch's driver interface: `DB::`, `SQLite3::`, and
  # the C bindings appear only in `src/punch/database/driver.cr` and
  # `src/punch/database/shell.cr`, and only those require the `db` and
  # `sqlite3` shards. Application code and generated code use
  # `Punch::Reader`, `Punch::Writer`, and generated query methods, so the
  # implementation underneath can change without touching them.
  #
  # ```
  # Punch/DriverTypes:
  #   Enabled: true
  # ```
  class DriverTypes < Base
    properties do
      since_version "1.7.0"
      description "Reports SQLite driver types outside Punch's database layer"
      allowed_paths ["src/punch/database/driver.cr", "src/punch/database/shell.cr"]
    end

    FORBIDDEN = %w[DB SQLite3 LibSQLite3 LibPunchSQLite LibPunchSQLiteShell]
    SHARDS    = %w[db sqlite3]

    MSG         = "`%s` is a SQLite driver type. Use Punch::Reader, Punch::Writer, or generated queries (lib/punch/docs/persistence.md)"
    MSG_REQUIRE = "Requiring `%s` reaches SQLite past Punch's driver interface (lib/punch/docs/persistence.md)"

    # Ameba's node visitor skips paths and requires, so this rule walks the
    # tree itself.
    def test(source : Source)
      return if allowed?(source)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.paths.each { |node| issue_for node, MSG % node }
      visitor.requires.each { |node| issue_for node, MSG_REQUIRE % node.string }
    end

    private class Finder < Crystal::Visitor
      getter paths = [] of Crystal::Path
      getter requires = [] of Crystal::Require

      def visit(node : Crystal::Path)
        paths << node if FORBIDDEN.includes?(node.names.first)
        true
      end

      def visit(node : Crystal::Require)
        name = node.string
        requires << node if SHARDS.includes?(name) || SHARDS.any? { |shard| name.starts_with?("#{shard}/") }
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end

    private def allowed?(source) : Bool
      allowed_paths.any? { |path| source.path == path || source.path.ends_with?("/#{path}") }
    end
  end
end
