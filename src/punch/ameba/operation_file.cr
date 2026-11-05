module Ameba::Rule::Punch
  # One file per type a tool shows by name, named after it: a Query or
  # Command in its namespace's `operations/` directory
  # (`Billing::Invoices::Send` in `…/billing/invoices/operations/send.cr`),
  # a Page in `pages/` (`…/pages/show_page.cr`), a job (`include
  # Punch::Job`) in `jobs/`, a mail (`include Punch::Mail`) in `mail/`, a
  # subscriber (`include Punch::Subscriber(…)`) in `subscribers/`. A name
  # in a trace, a route table, the ops console, or an error then says which
  # file to open, and listing `operations/` lists the namespace's API.
  # Types only that one uses go in its file too; shared ones in the
  # namespace's `results.cr` and `components.cr` (docs/structure.md).
  # Applies to app code (files under `app/`).
  #
  # ```
  # Punch/OperationFile:
  #   Enabled: true
  # ```
  class OperationFile < Base
    properties do
      since_version "1.7.0"
      description "Reports a Query, Command, Page, job, mail, or subscriber outside the file named after it in operations/, pages/, jobs/, mail/, or subscribers/"
    end

    MSG = "`%s` belongs in `%s`: one file per operation, page, job, mail, and subscriber, named after it (lib/punch/docs/structure.md)"

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.operations.each do |node, names, directory|
        expected = (names[0...-1].map(&.underscore) + [directory, names.last.underscore + ".cr"]).join('/')
        next if source.path == expected || source.path.ends_with?("/#{expected}")
        issue_for node, MSG % {names.join("::"), expected}
      end
    end

    # Modules whose includers are shown by name, and their directory.
    INCLUDED = {"Job" => "jobs", "Mail" => "mail", "Subscriber" => "subscribers"}

    # Collects operations, pages, jobs, mails, and subscribers with their
    # full names and directory.
    private class Finder < Crystal::Visitor
      getter operations = [] of {Crystal::ClassDef, Array(String), String}
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
        superclass = node.superclass
        if superclass.is_a?(Crystal::Path) && superclass.names.last.in?("Command", "Query", "Page")
          operations << {node, @namespace + names, superclass.names.last == "Page" ? "pages" : "operations"}
        elsif directory = included(node.body)
          operations << {node, @namespace + names, directory}
        end
        @namespace.concat(names)
        true
      end

      # The directory of the first shown module *body* includes.
      private def included(body : Crystal::ASTNode) : String?
        members = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        members.each do |member|
          next unless member.is_a?(Crystal::Include)
          name = member.name
          name = name.name if name.is_a?(Crystal::Generic)
          next unless name.is_a?(Crystal::Path)
          names = name.names
          next unless names.size == 1 || (names.size == 2 && names.first == "Punch")
          directory = INCLUDED[names.last]?
          return directory if directory
        end
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
