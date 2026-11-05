module Punch::CLI::Commands
  # Prints the event graph of the application it is compiled into: every
  # event, the operations that may publish it, and its subscribers with
  # their delivery and the cache stores they forget entries of.
  class Events < Command
    command "events", "List the domain events, who publishes them, and who subscribes, with the delivery"

    struct Result
      include Report

      def initialize(@graph : Array(Punch::Subscribers::Node))
      end

      def to_text(io : IO) : Nil
        return io.puts("No events: the application defines none.") if @graph.empty?

        @graph.each_with_index do |node, index|
          io.puts if index > 0
          io.puts node.event
          io.puts "  published by nobody" if node.publishers.empty?
          node.publishers.each { |publisher| io.puts "  published by  #{publisher}" }
          node.subscribers.each do |subscriber, delivery|
            io << "  " << delivery.ljust(12) << "  " << subscriber
            forgets(node, subscriber).try { |store| io << "  (forgets cache " << store << ')' }
            io.puts
          end
        end
      end

      # The cache store *subscriber* forgets entries of, if any.
      private def forgets(node : Punch::Subscribers::Node, subscriber : String) : String?
        node.forgets.find { |name, _| name == subscriber }.try(&.[1])
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "events" do
            json.array do
              @graph.each do |node|
                json.object do
                  json.field "event", node.event
                  json.field "publishers", node.publishers
                  json.field "subscribers" do
                    json.array do
                      node.subscribers.each do |subscriber, delivery|
                        json.object do
                          json.field "subscriber", subscriber
                          json.field "delivery", delivery
                          json.field "forgets", forgets(node, subscriber)
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      no_arguments(args) || Result.new(Punch::Subscribers.graph)
    end
  end
end
