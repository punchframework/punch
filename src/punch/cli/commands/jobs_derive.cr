module Punch::CLI::Commands
  # Derives the payload lock of the application it is compiled into: each
  # stored job type, the payload it carries, and that payload's version
  # and schemas. Only in the derivation build (`-Dpunch_openapi`), which
  # `punch jobs:lock` makes; run that instead.
  class JobsDerive < Command
    command "jobs:derive", "Derive the payload lock (used by punch jobs:lock)"

    struct Result
      include Report

      def initialize(@lock : JSON::Any)
      end

      def to_text(io : IO) : Nil
        io.puts @lock.to_pretty_json
      end

      def to_json(json : JSON::Builder) : Nil
        @lock.to_json(json)
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end
      {% if flag?(:punch_openapi) %}
        Result.new(Punch::Job::Queue::Registry.lock)
      {% else %}
        Failure.new("not_derivation_build", "jobs:derive is only in the derivation build; run punch jobs:lock.")
      {% end %}
    end
  end
end
