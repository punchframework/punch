module Ameba::Rule::Punch
  # Keeps calls to other systems out of requests (docs/jobs.md): an
  # operation (a `Command`, `Query`, or `Page` in app code) does not make
  # HTTP requests, open sockets, start processes, or deliver mail. Inside
  # `call` such a call holds the transaction, and the database's one
  # writer, for as long as the other system takes, and happens even when
  # the Command then rolls back. Enqueue a job through
  # `jobs : Punch::Jobs(...)`, or publish an event with a `:deferred`
  # subscriber: it runs after the commit and is retried.
  #
  # Reported inside an operation: `HTTP::Client`, the socket types
  # (`TCPSocket`, `UDPSocket`, `UNIXSocket`, `Socket`, `OpenSSL::SSL::Socket`),
  # `Process.run`, `Process.new`, and `Mailer.deliver`.
  #
  # ```
  # Punch/OutsideCalls:
  #   Enabled: true
  # ```
  class OutsideCalls < Base
    properties do
      since_version "1.7.0"
      description "Reports HTTP, sockets, processes, and mail delivery in operations"
    end

    MSG = "`%s` in an operation calls another system inside the request: enqueue a job (`jobs : Punch::Jobs(...)`) or publish an event to a `:deferred` subscriber, which run after the commit and are retried (lib/punch/docs/jobs.md)"

    SOCKETS = %w[TCPSocket UDPSocket UNIXSocket Socket]

    def test(source : Source)
      return unless Operations.app_code?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.found.each { |node, text| issue_for node, MSG % text }
    end

    private class Finder < Crystal::Visitor
      getter found = [] of {Crystal::ASTNode, String}
      @operations = 0

      def visit(node : Crystal::ClassDef)
        @operations += 1 if Operations.operation?(node)
        true
      end

      def end_visit(node : Crystal::ClassDef)
        @operations -= 1 if Operations.operation?(node)
      end

      def visit(node : Crystal::Path)
        found << {node, node.to_s} if @operations > 0 && outside?(node.names)
        true
      end

      def visit(node : Crystal::Call)
        receiver = node.obj
        if @operations > 0 && receiver.is_a?(Crystal::Path) && call_out?(receiver.names.last, node.name)
          found << {node, "#{receiver}.#{node.name}"}
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      private def outside?(names : Array(String)) : Bool
        names.each_cons(2).any?(&.==(%w[HTTP Client])) || (names.size == 1 && names.first.in?(SOCKETS)) ||
          names.each_cons(3).any?(&.==(%w[OpenSSL SSL Socket]))
      end

      private def call_out?(receiver : String, name : String) : Bool
        (receiver == "Process" && name.in?("run", "new")) || (receiver == "Mailer" && name == "deliver")
      end
    end
  end
end
