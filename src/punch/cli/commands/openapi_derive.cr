module Punch::CLI::Commands
  # Derives the OpenAPI document of the application it is compiled into,
  # with the type behind each schema and operation. Only in the build
  # `punch openapi` makes (`-Dpunch_openapi`), which writes `openapi.json`
  # from it; run that instead.
  class OpenAPIDerive < Command
    command "openapi:derive", "Derive the OpenAPI document (used by punch openapi): openapi:derive TITLE VERSION"

    struct Result
      include Report

      def initialize(@derived : Punch::OpenAPI::Derived)
      end

      def to_text(io : IO) : Nil
        io.puts @derived.document.to_pretty_json
      end

      def to_json(json : JSON::Builder) : Nil
        @derived.to_json(json)
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("missing_argument", "Usage: openapi:derive TITLE VERSION") unless args.size == 2

      Result.new(Punch::OpenAPI.derive(args[0], args[1]))
    end
  end
end
