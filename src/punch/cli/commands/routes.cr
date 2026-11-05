module Punch::CLI::Commands
  # Prints the route table of the application it is compiled into.
  class Routes < Command
    command "routes", "List the routes derived from the operations and pages"

    struct Result
      include Report

      def initialize(@routes : Array(Punch::Routing::Route))
      end

      def to_text(io : IO) : Nil
        if @routes.empty?
          io.puts "No routes: the application defines no operations."
          return
        end
        method_width = @routes.max_of(&.method.size)
        path_width = @routes.max_of(&.template.size)
        surfaces_width = @routes.max_of(&.surfaces.join(',').size)
        @routes.each do |route|
          io << route.method.ljust(method_width) << "  " << route.template.ljust(path_width) << "  " << route.surfaces.join(',').ljust(surfaces_width) << "  " << route.operation
          route.form_page.try { |page| io << "  (form on " << page << ')' }
          if policy = route.policy
            io << "  (policy: " << policy << ')'
          elsif route.public
            io << "  (public)"
          end
          io << "  (limited: " << route.rate_limits.join(", ", &.name) << ')' unless route.rate_limits.empty?
          io << "  (unlisted)" if route.unlisted
          io << "  (entry point)" if route.entry
          io.puts
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "routes" do
            json.array do
              @routes.each do |route|
                json.object do
                  json.field "method", route.method
                  json.field "path", route.template
                  json.field "operation", route.operation
                  json.field "operation_id", route.operation_id
                  json.field "kind", route.kind.to_s.downcase
                  # What it answers: json, html, markdown.
                  json.field "surfaces", route.surfaces
                  # The page that holds a Command's form, if one does.
                  json.field "form_page", route.form_page if route.form_page
                  # Whether `call` needs a signed-in user: required, optional, none.
                  json.field "actor", route.actor
                  json.field "rate_limits" do
                    json.array { route.rate_limits.each { |limiter| RateLimitsCommand.limiter_json(json, limiter) } }
                  end
                  json.field "rate_limit_exempt", route.rate_limit_exempt if route.rate_limit_exempt
                  # The policy of `@[Punch::Authorize]`, and whether the
                  # operation is `@[Punch::Public]`.
                  json.field "policy", route.policy
                  json.field "public", route.public
                  # Left out of openapi.json (`@[Punch::Unlisted]`).
                  json.field "unlisted", route.unlisted
                  # Listed in /llms.txt (`@[Punch::AgentReadable(entry: true)]`).
                  json.field "entry", route.entry
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      no_arguments(args) || Result.new(Punch::Routing.routes.sort_by { |route| {route.template, route.method, route.kind.value} })
    end
  end
end
