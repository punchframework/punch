module Ameba::Rule::Punch
  # Keeps `punch events` true: a Command publishes through the
  # `Punch::Events(...)` its `call` asks for, which the router makes and
  # whose type is the declaration the event graph prints. A handle made by
  # hand, with `Events(...).for_transaction`, publishes events nobody can
  # see in the graph. Specs use `Punch::Spec.events(Command, writer)`. The
  # same holds for the outbox handle `Punch::Jobs(...)`: its type is what
  # tells which Commands enqueue which jobs (`Punch::Spec.jobs`).
  #
  # ```
  # Punch/EventsHandle:
  #   Enabled: true
  # ```
  class EventsHandle < Base
    properties do
      since_version "1.7.0"
      description "Reports events and jobs handles made by hand"
    end

    JOBS_MSG = "Ask for `jobs : Punch::Jobs(...)` in the Command's `call` instead of making a handle: the type in `call` declares what it enqueues (lib/punch/docs/jobs.md)"
    MSG      = "Ask for `events : Punch::Events(...)` in the Command's `call` instead of making a handle: the type in `call` is what `punch events` shows (lib/punch/docs/events.md)"

    def test(source : Source)
      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.calls.each { |node| issue_for node, Finder.handle(node.obj) == "Jobs" ? JOBS_MSG : MSG }
    end

    private class Finder < Crystal::Visitor
      getter calls = [] of Crystal::Call

      def visit(node : Crystal::Call)
        calls << node if node.name == "for_transaction" && Finder.handle(node.obj)
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      # `Events` or `Jobs` when *receiver* names one of the handles.
      def self.handle(receiver : Crystal::ASTNode?) : String?
        receiver = receiver.name if receiver.is_a?(Crystal::Generic)
        return unless receiver.is_a?(Crystal::Path)

        name = receiver.names.last
        name if name.in?("Events", "Jobs")
      end
    end
  end
end
