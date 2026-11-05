require "json"

module Punch::Bareknuckle
  # One line per `punch dev` round in `tmp/punch-dev/rounds.jsonl`, and one
  # per `punch typecheck` in `tmp/punch-dev/typecheck.jsonl`: what each
  # round cost. Read back by `punch dev:rounds`.
  module RoundLog
    DIRECTORY = "tmp/punch-dev"
    ROUNDS    = "#{DIRECTORY}/rounds.jsonl"
    TYPECHECK = "#{DIRECTORY}/typecheck.jsonl"
    # One line per verification build (`Punch::CLI::DevLoop`).
    VERIFY = "#{DIRECTORY}/verify.jsonl"

    # A finished round. *tier* is `first` for the round that starts
    # `punch dev`, which has no build before it to compare with. A
    # *skipped* round needed no build (only assets changed). *path* is how
    # it was built (`fast`, `bareknuckle` or `crystal`, see
    # `Punch::CLI::DevLoop`), *refused* why the fast path did not apply,
    # and *modules* what the fast path generated.
    record Round, number : Int32, at : Time, edits : Array(Edit), tier : String,
      built : Bool, build_seconds : Float64, stats : Stats, boot_seconds : Float64?, seconds : Float64, skipped : Bool = false,
      path : String? = nil, refused : String? = nil, modules : Array(String)? = nil do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "round", number
          json.field "at", at.to_rfc3339
          json.field "tier", tier
          json.field "edits", edits
          json.field "built", built
          json.field "skipped", skipped
          json.field "build_seconds", build_seconds.round(3)
          json.field "stats", stats
          json.field "boot_seconds", boot_seconds.try(&.round(3))
          json.field "seconds", seconds.round(3)
          json.field "path", path if path
          json.field "refused", refused if refused
          json.field "modules", modules if modules
        end
      end
    end

    def self.append(path : String, entry) : Nil
      Dir.mkdir_p(File.dirname(path))
      File.open(path, "a", &.puts(entry.to_json))
    end

    # The entries of *path*, oldest first; lines that do not parse are left
    # out.
    def self.read(path : String) : Array(JSON::Any)
      return [] of JSON::Any unless File.exists?(path)

      File.read_lines(path).compact_map { |line| JSON.parse(line) rescue nil }
    end
  end
end
