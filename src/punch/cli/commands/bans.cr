module Punch::CLI::Commands
  # The addresses banned for probing (`docs/http.md`, "Probes and bans"),
  # from `cache.db`: active bans, and earlier ones whose count is still
  # remembered.
  class BansList < Command
    command "bans", "List the addresses banned for asking for paths only scanners ask for, from cache.db"

    struct Result
      include Report

      def initialize(@bans : Array(Punch::HTTP::Probes::Ban), @now : Time)
      end

      def to_text(io : IO) : Nil
        active = @bans.select(&.active?(@now))
        io.puts active.empty? ? "No address is banned." : "#{active.size} address(es) banned:"
        active.each { |ban| line(io, ban) }
        ended = @bans.reject(&.active?(@now))
        return if ended.empty?

        io.puts "Ended, counted for the next ban until #{Punch::HTTP::Probes::Settings::FORGET.total_days.to_i} days after:"
        ended.each { |ban| line(io, ban) }
      end

      private def line(io : IO, ban : Punch::HTTP::Probes::Ban) : Nil
        io << "  " << ban.address << "  ban " << ban.strikes << ", until " << ban.ends_at.to_s("%Y-%m-%d %H:%M:%S UTC")
        io << "  " << ban.paths.join(" ") unless ban.paths.empty?
        io.puts
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "bans" do
            json.array do
              @bans.each do |ban|
                json.object do
                  json.field "address", ban.address
                  json.field "active", ban.active?(@now)
                  json.field "strikes", ban.strikes
                  json.field "banned_at", ban.banned_at.to_rfc3339
                  json.field "ends_at", ban.ends_at.to_rfc3339
                  json.field "paths", ban.paths
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      CacheCommand.with_durable do |durable|
        Result.new(Punch::HTTP::Probes.list(durable.database), Time.utc)
      end
    end
  end

  # Lifts a ban and forgets the address's count; a running server notices
  # within 30 seconds.
  class BansLift < Command
    command "bans:lift", "Lift the ban of an address in cache.db: punch bans:lift ADDRESS"

    struct Result
      include Report

      def initialize(@address : String)
      end

      def to_text(io : IO) : Nil
        io.puts "Lifted the ban of #{@address}; a running server lets it in within #{Punch::HTTP::Probes::Settings::POLL.total_seconds.to_i} s."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "address", @address }
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("missing_argument", "Usage: bans:lift ADDRESS") unless args.size == 1

      address = Punch::HTTP::Probes.address_key(args[0]) || return Failure.usage("invalid_address", "#{args[0].inspect} is not an IPv4 or IPv6 address.")
      CacheCommand.with_durable do |durable|
        next Failure.new("not_banned", "#{address} is not banned; see 'bans'.") unless Punch::HTTP::Probes.lift(durable.database, address)

        Result.new(address)
      end
    end
  end
end
