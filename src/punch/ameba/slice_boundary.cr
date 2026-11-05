module Ameba::Rule::Punch
  # Keeps slices apart (docs/structure.md): code in one slice (a directory
  # under `app/`) does not reach into another's data access, its generated
  # `Table` and `Queries` and its `Store` (or any type named `…Store`).
  # How a slice keeps its rows is its own; another slice uses its
  # operations, policies, IDs, records, events, and results, or a
  # function it offers for the purpose (`Accounts::Mailing`). Files
  # directly in `app/` (the actor, settings) belong to no slice and are
  # not checked; nor are generated files and specs.
  #
  # ```
  # Punch/SliceBoundary:
  #   Enabled: true
  # ```
  class SliceBoundary < Base
    properties do
      since_version "1.7.0"
      description "Reports one slice reaching into another's tables, queries, or store"
    end

    MSG = "`%s` reaches into the %s slice's data: use its operations or policies, or a function it offers for this, instead of its tables, queries, or store (lib/punch/docs/structure.md)"

    def test(source : Source)
      path = source.path
      return unless Operations.app_code?(path)

      root, slice = location(path) || return
      others = slices(root) - [slice]
      return if others.empty?

      visitor = Finder.new(others)
      source.ast.accept(visitor)
      visitor.paths.each { |node, name| issue_for node, MSG % {node.names.join("::"), name} }
    end

    # The directory holding `app/`, and the slice of the file at *path*
    # (camel-cased); nil for a file directly in `app/` that outlines no
    # slice directory.
    private def location(path : String) : {String, String}?
      index = path.starts_with?("app/") ? 0 : (path.index("/app/").try(&.+(1)) || return)
      root = path[0, index]
      rest = path[(index + 4)..]
      first = rest.split('/').first.rchop(".cr")
      return if !rest.includes?('/') && !Dir.exists?(File.join(root, "app", first))

      {root, first.camelcase}
    end

    # The slices of the app whose `app/` is in *root*.
    private def slices(root : String) : Array(String)
      directory = File.join(root, "app")
      return [] of String unless Dir.exists?(directory)

      Dir.children(directory).select { |name| Dir.exists?(File.join(directory, name)) }.map(&.camelcase)
    end

    private class Finder < Crystal::Visitor
      getter paths = [] of {Crystal::Path, String}

      def initialize(@others : Array(String))
      end

      def visit(node : Crystal::Path)
        names = node.names
        if names.size >= 2 && @others.includes?(names.first) && names[1..].any? { |name| data?(name) }
          paths << {node, names.first.underscore}
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      private def data?(name : String) : Bool
        name.in?("Table", "Queries") || name.ends_with?("Store")
      end
    end
  end
end
