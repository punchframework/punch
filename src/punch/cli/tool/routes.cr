require "./project"

module Punch::CLI::Commands
  # `punch routes` for the app in the current directory: builds it and
  # asks the binary, which knows its operations (`Commands::Routes`).
  class ToolRoutes < Command
    command "routes", "Build the app and list the routes derived from its operations and pages"

    BINARY = "tmp/punch-routes/app"

    struct Result
      include Report

      def initialize(@document : JSON::Any)
      end

      def to_text(io : IO) : Nil
        routes = @document["routes"].as_a
        return io.puts("No routes: the application defines no operations.") if routes.empty?

        method_width = routes.max_of(&.["method"].as_s.size)
        path_width = routes.max_of(&.["path"].as_s.size)
        surfaces_width = routes.max_of { |route| surfaces(route).size }
        routes.each do |route|
          io << route["method"].as_s.ljust(method_width) << "  " << route["path"].as_s.ljust(path_width) << "  " << surfaces(route).ljust(surfaces_width) << "  " << route["operation"]
          route["form_page"]?.try { |page| io << "  (form on " << page << ')' }
          io.puts
        end
      end

      def to_json(json : JSON::Builder) : Nil
        @document.to_json(json)
      end

      private def surfaces(route : JSON::Any) : String
        route["surfaces"].as_a.join(',', &.as_s)
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      project = Project.load
      return project if project.is_a?(Failure)

      build = Project.build(project.main, BINARY)
      return Failure.new("build_failed", "Building #{project.main} failed:\n#{build.output}") unless build.success

      output, error = IO::Memory.new, IO::Memory.new
      status = Process.run(BINARY, ["routes", "--json"], output: output, error: error)
      return Failure.new("routes_failed", "#{BINARY} routes failed:\n#{error}#{output}") unless status.success?

      Result.new(JSON.parse(output.to_s))
    end
  end
end
