module Ameba::Rule::Punch
  # Keeps a record's behaviour where the generated file says it is: a struct
  # named `Record` is reopened only in the file named after it, as Crystal
  # names any type's file. `Billing::Customers::Record` lives in
  # `…/billing/customers/record.cr`, so `records.gen.cr` can point there and
  # readers find every rule about customers in one place. Generated files
  # are skipped.
  #
  # ```
  # Punch/RecordFile:
  #   Enabled: true
  # ```
  class RecordFile < Base
    properties do
      since_version "1.7.0"
      description "Reports a Record struct outside the record.cr file named after it"
    end

    MSG = "`%s` belongs in `%s`, the file named after it, where the generated record points (lib/punch/docs/models.md)"

    def test(source : Source)
      return if source.path.ends_with?(".gen.cr")

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.records.each do |node, name|
        expected = name.split("::").join('/', &.underscore) + ".cr"
        next if source.path == expected || source.path.ends_with?("/#{expected}")
        issue_for node, MSG % {name, expected}
      end
    end

    # Collects `struct …::Record` definitions with their full names.
    private class Finder < Crystal::Visitor
      getter records = [] of {Crystal::ClassDef, String}
      @namespace = [] of String

      def visit(node : Crystal::ModuleDef)
        @namespace.concat(node.name.names)
        true
      end

      def end_visit(node : Crystal::ModuleDef)
        @namespace.pop(node.name.names.size)
      end

      def visit(node : Crystal::ClassDef)
        names = node.name.names
        records << {node, (@namespace + names).join("::")} if node.struct? && names.last == "Record"
        @namespace.concat(names)
        true
      end

      def end_visit(node : Crystal::ClassDef)
        @namespace.pop(node.name.names.size)
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
