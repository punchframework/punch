require "./project"
require "../../bareknuckle"

module Punch::CLI::Commands
  # `punch dev:rounds`: what the `punch dev` rounds and `punch typecheck`
  # runs logged in `tmp/punch-dev/` cost, by the tier a warm compiler would
  # have needed: how many rounds, their share, and the median time of each
  # part of the build and of the app's boot. When the bareknuckle daemon
  # built rounds (`Bareknuckle::Daemon`), also how: rounds and median build
  # time on the fast path, in a full daemon build, and with `crystal build`,
  # why the fast path did not apply, and what the verification builds found.
  class DevRounds < Command
    command "dev:rounds", "Summarize the logged punch dev rounds and typechecks: share and median times per incremental tier"

    TIERS  = %w[fast propagation full none first]
    GROUPS = %w[typing ir objects link]

    record Row, tier : String, rounds : Int32, share : Float64, build : Float64?,
      groups : Hash(String, Float64?), boot : Float64?, rebuilt : Float64?

    # The rounds after the first by how they were built (`fast`,
    # `bareknuckle`, `crystal`): how many and their median build time;
    # why the fast path did not apply, by reason; and the verification
    # builds, how many and the rounds that differed.
    record Daemon, paths : Hash(String, {Int32, Float64?}), refusals : Hash(String, Int32),
      verified : Int32, differed : Array(Int32)

    struct Result
      include Report

      def initialize(@rows : Array(Row), @rounds : Int32, @typechecks : Int32,
                     @typecheck : Float64?, @typing : Float64?, @daemon : Daemon? = nil)
      end

      def to_text(io : IO) : Nil
        io.puts "#{@rounds} rounds after the first (#{Bareknuckle::RoundLog::ROUNDS}); medians in seconds:"
        io.puts "  #{"tier".ljust(12)} rounds  share  build  typing     ir objects   link   boot  rebuilt"
        @rows.each do |row|
          io << "  " << row.tier.ljust(12) << row.rounds.to_s.rjust(6) << "#{(row.share * 100).round.to_i}%".rjust(7)
          io << cell(row.build)
          GROUPS.each { |group| io << cell(row.groups[group]?) }
          io << cell(row.boot) << (row.rebuilt.try(&.round.to_i.to_s) || "-").rjust(9) << '\n'
        end
        if @typechecks > 0
          io.puts "typecheck: #{@typechecks} runs, median #{@typecheck.try(&.round(1))} s (typing #{@typing.try(&.round(1))} s)"
        end
        @daemon.try do |daemon|
          io.puts "bareknuckle: #{daemon.paths.join(", ") { |path, (rounds, build)| "#{rounds} #{path} (median #{build.try(&.round(2))} s)" }}"
          daemon.refusals.to_a.sort_by! { |(_, count)| -count }.first(5).each do |(reason, count)|
            io.puts "  full build #{count}× for: #{reason}"
          end
          io.puts "  #{daemon.verified} verification builds#{daemon.differed.empty? ? ", no difference" : ", differences in rounds #{daemon.differed.join(", ")}"}" if daemon.verified > 0
        end
      end

      private def cell(value : Float64?) : String
        (value.try(&.round(2).to_s) || "-").rjust(7)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "rounds", @rounds
          json.field "tiers" do
            json.array do
              @rows.each do |row|
                json.object do
                  json.field "tier", row.tier
                  json.field "rounds", row.rounds
                  json.field "share", row.share.round(3)
                  json.field "build_seconds", row.build
                  json.field "groups", row.groups
                  json.field "boot_seconds", row.boot
                  json.field "rebuilt_modules", row.rebuilt
                end
              end
            end
          end
          json.field "typecheck" do
            json.object do
              json.field "runs", @typechecks
              json.field "seconds", @typecheck
              json.field "typing_seconds", @typing
            end
          end
          @daemon.try do |daemon|
            json.field "bareknuckle" do
              json.object do
                json.field "paths" do
                  json.object do
                    daemon.paths.each do |path, (rounds, build)|
                      json.field(path) do
                        json.object do
                          json.field "rounds", rounds
                          json.field "build_seconds", build
                        end
                      end
                    end
                  end
                end
                json.field "refusals", daemon.refusals
                json.field "verified", daemon.verified
                json.field "differed", daemon.differed
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

      rounds = Bareknuckle::RoundLog.read(Bareknuckle::RoundLog::ROUNDS).select { |round| round["built"]?.try(&.as_bool?) || round["skipped"]?.try(&.as_bool?) }
      return Failure.new("no_rounds", "No built round is logged in #{Bareknuckle::RoundLog::ROUNDS}; run 'punch dev' and edit the app first.") if rounds.empty?

      later = rounds.count { |round| round["tier"].as_s != "first" }
      rows = TIERS.compact_map do |tier|
        these = rounds.select { |round| round["tier"].as_s == tier }
        next if these.empty?

        groups = GROUPS.to_h { |group| {group, DevRounds.median(these.compact_map { |round| round.dig?("stats", "groups", group).try(&.as_f?) })} }
        rebuilt = DevRounds.median(these.compact_map { |round| round.dig?("stats", "reuse").try(&.as_s?) == "some" ? round.dig("stats", "rebuilt").as_a.size.to_f : nil })
        share = tier == "first" || later.zero? ? 0.0 : these.size / later
        Row.new(tier, these.size, share, DevRounds.median(these.map(&.["build_seconds"].as_f)), groups,
          DevRounds.median(these.compact_map(&.["boot_seconds"]?.try(&.as_f?))), rebuilt)
      end
      checks = Bareknuckle::RoundLog.read(Bareknuckle::RoundLog::TYPECHECK).select(&.["success"]?.try(&.as_bool?))
      Result.new(rows, later, checks.size, DevRounds.median(checks.map(&.["seconds"].as_f)),
        DevRounds.median(checks.compact_map(&.dig?("stats", "groups", "typing").try(&.as_f?))), DevRounds.daemon(rounds))
    end

    # How the daemon built *rounds*; `nil` when it built none.
    def self.daemon(rounds : Array(JSON::Any)) : Daemon?
      later = rounds.select { |round| round["tier"].as_s != "first" && round["path"]?.try(&.as_s?) }
      return if later.none? { |round| round["path"].as_s != "crystal" }

      paths = later.group_by(&.["path"].as_s).transform_values do |these|
        {these.size, median(these.map(&.["build_seconds"].as_f))}
      end
      refusals = later.compact_map(&.["refused"]?.try(&.as_s?)).tally
      verifications = Bareknuckle::RoundLog.read(Bareknuckle::RoundLog::VERIFY)
      differed = verifications.reject(&.["mismatches"].as_a.empty?).map(&.["round"].as_i)
      Daemon.new(paths, refusals, verifications.size, differed)
    end

    # The median of *values*; `nil` for none.
    def self.median(values : Array(Float64)) : Float64?
      return if values.empty?

      sorted = values.sort
      middle = sorted.size // 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    end
  end
end
