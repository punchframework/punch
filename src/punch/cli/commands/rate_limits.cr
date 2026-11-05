module Punch::CLI::Commands
  # Helpers shared by the rate-limit commands (docs/rate-limits.md).
  module RateLimitsCommand
    def self.limiter_json(json : JSON::Builder, limiter : Punch::RateLimits::Limiter) : Nil
      json.object do
        json.field "name", limiter.name
        json.field "limit", limiter.limit
        json.field "period_seconds", limiter.period.total_seconds
        json.field "by", limiter.by
        json.field "store", limiter.store.to_s.downcase
      end
    end
  end

  # The app's rate limits: each operation's, with its policy. Durable
  # limits also show how many keys are limited or recovering in
  # `cache.db`; memory limits live inside the server process, so their
  # keys and counts are not visible here.
  class RateLimitsList < Command
    command "limits", "List the rate limits of the app's operations, with keys held in cache.db"

    record Entry, operation : String, limiter : Punch::RateLimits::Limiter, keys : Int64?

    struct Result
      include Report

      def initialize(@entries : Array(Entry), @exempt : Array({String, String}))
      end

      def to_text(io : IO) : Nil
        io.puts "No rate limits." if @entries.empty?
        @entries.each do |entry|
          io << entry.limiter << "  " << entry.operation
          entry.keys.try { |keys| io << "  " << keys << " keys held" }
          io.puts
        end
        @exempt.each { |operation, reason| io.puts "exempt: #{operation}: #{reason}" }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "limits" do
            json.array do
              @entries.each do |entry|
                json.object do
                  json.field "operation", entry.operation
                  json.field "limit" { RateLimitsCommand.limiter_json(json, entry.limiter) }
                  json.field "keys", entry.keys
                end
              end
            end
          end
          json.field "exempt" do
            json.array { @exempt.each { |operation, reason| json.object { json.field "operation", operation; json.field "reason", reason } } }
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      routes = Punch::Routing.routes
      exempt = routes.compact_map { |route| route.rate_limit_exempt.try { |reason| {route.operation, reason} } }
      limited = routes.flat_map { |route| route.rate_limits.map { |limiter| {route.operation, limiter} } }
      return Result.new([] of Entry, exempt) unless limited.any? { |_, limiter| limiter.store.durable? }

      CacheCommand.with_durable do |durable|
        entries = limited.map do |operation, limiter|
          Entry.new(operation, limiter, limiter.store.durable? ? limiter.keys(database: durable.database) : nil)
        end
        Result.new(entries, exempt)
      end
    end
  end

  # Lets a key, or every key, of a durable limit start over, such as a
  # user locked out of signing in. Memory limits reset when the server
  # restarts.
  class RateLimitsReset < Command
    command "limits:reset", "Reset a durable rate limit in cache.db: punch limits:reset NAME [KEY]"

    struct Result
      include Report

      def initialize(@name : String, @key : String?)
      end

      def to_text(io : IO) : Nil
        io.puts "Reset #{@name}#{@key.try { |key| " for #{key}" } || ", every key"}."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "name", @name; json.field "key", @key }
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("missing_argument", "Usage: limits:reset NAME [KEY]") unless args.size.in?(1, 2)

      Punch::Routing.routes # creates the operations' limiters
      limiter = Punch::RateLimits.find(args[0]) || return Failure.new("unknown_limit", "No rate limit is named #{args[0]}; see 'limits'.")
      return Failure.new("memory_limit", "#{limiter.name} is kept in the server's memory; it resets when the server restarts.") if limiter.store.memory?

      CacheCommand.with_durable do |durable|
        limiter.reset(args[1]?, database: durable.database)
        Result.new(limiter.name, args[1]?)
      end
    end
  end
end
