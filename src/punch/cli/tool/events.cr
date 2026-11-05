require "./project"
require "./routes"

module Punch::CLI::Commands
  # `punch events` for the app in the current directory: builds it and asks
  # the binary, which knows its events (`Commands::Events`).
  class ToolEvents < Command
    command "events", "Build the app and list its domain events, publishers, and subscribers"

    struct Result
      include Report

      def initialize(@document : JSON::Any)
      end

      def to_text(io : IO) : Nil
        events = @document["events"].as_a
        return io.puts("No events: the application defines none.") if events.empty?

        events.each_with_index do |node, index|
          io.puts if index > 0
          io.puts node["event"]
          publishers = node["publishers"].as_a
          io.puts "  published by nobody" if publishers.empty?
          publishers.each { |publisher| io.puts "  published by  #{publisher}" }
          node["subscribers"].as_a.each { |subscriber| io.puts "  #{subscriber["delivery"].as_s.ljust(12)}  #{subscriber["subscriber"]}" }
        end
      end

      def to_json(json : JSON::Builder) : Nil
        @document.to_json(json)
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      project = Project.load
      return project if project.is_a?(Failure)

      # The same binary as `punch routes`: one build serves both.
      binary = ToolRoutes::BINARY
      build = Project.build(project.main, binary)
      return Failure.new("build_failed", "Building #{project.main} failed:\n#{build.output}") unless build.success

      output, error = IO::Memory.new, IO::Memory.new
      status = Process.run(binary, ["events", "--json"], output: output, error: error)
      return Failure.new("events_failed", "#{binary} events failed:\n#{error}#{output}") unless status.success?

      Result.new(JSON.parse(output.to_s))
    end
  end
end
