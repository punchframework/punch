require "./project"
require "../../jobs/lock"

module Punch::CLI::Commands
  # Writes `payloads.lock.json` for the app in the current directory: builds
  # the derivation build, runs its `jobs:derive`, compares the result with
  # the committed lock, and writes it unless a change breaks payloads that
  # binaries on either side of a deploy must read. With `--check`, writes
  # nothing and also fails when the file is stale.
  class JobsLock < Command
    command "jobs:lock", "Write payloads.lock.json from the app's jobs and events; --check compares; --drop TYPE acknowledges a removed job type, --drop 'TYPE#step' a removed step"

    FILE = Punch::Payloads::Lock::FILE

    struct Result
      include Report

      def initialize(@state : String, @lock : JSON::Any, @notes : Array(String))
      end

      def to_text(io : IO) : Nil
        documents = @lock["documents"]?.try(&.as_h.size) || 0
        io.puts "#{@state.ljust(9)} #{FILE} (#{@lock["types"].as_h.size} job types, #{@lock["payloads"].as_h.size} payloads#{documents > 0 ? ", #{documents} document#{documents == 1 ? "" : "s"}" : ""})"
        @notes.each { |note| io.puts "  #{note}" }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", FILE
          json.field "state", @state
          json.field "types", @lock["types"].as_h.size
          json.field "payloads", @lock["payloads"].as_h.size
          json.field "documents", @lock["documents"]?.try(&.as_h.size) || 0
          json.field "notes", @notes
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      options = JobsLock.options(args)
      return options if options.is_a?(Failure)

      check, drops = options
      project = Project.load
      return project if project.is_a?(Failure)

      derived = JobsLock.derive(project)
      return derived if derived.is_a?(Failure)
      if kept = drops.find { |type| derived["types"].as_h.has_key?(type) }
        return Failure.usage("not_removed", "#{kept} is still a job type of the app; --drop is for types that are gone.")
      end
      if kept = drops.find { |drop| JobsLock.step?(derived, drop) }
        return Failure.usage("not_removed", "#{kept} is still a step of the app; --drop is for steps that are gone.")
      end

      JobsLock.settle(derived, drops, check)
    end

    # Compares *derived* with the committed lock, then writes it, or with
    # *check* only says whether it is current.
    def self.settle(derived : JSON::Any, drops : Array(String), check : Bool) : Report | Failure
      current = File.exists?(FILE) ? File.read(FILE) : nil
      lock = begin
        current.try { |text| JSON.parse(text) }
      rescue ex : JSON::ParseException
        return Failure.new("invalid_lock", "#{FILE} does not parse: #{ex.message}. Restore it from version control; never edit it by hand.")
      end
      comparison = Punch::Payloads::Lock.new(lock, derived, drops)
      unless comparison.ok?
        return Failure.new("breaking_payload_change", "#{comparison.problems.size == 1 ? "A change" : "Changes"} that stored payloads cannot follow:\n  " \
                                                      "#{comparison.problems.join("\n  ")}#{comparison.ways_out}")
      end
      text = derived.to_pretty_json + "\n"
      if check
        return Result.new("current", derived, comparison.notes) if current == text

        return Failure.new("stale_payload_lock", "#{FILE} does not match the app's jobs and events#{comparison.notes.empty? ? "" : " (#{comparison.notes.join("; ")})"}. " \
                                                 "Run 'punch jobs:lock' and commit the result; never edit it by hand.")
      end
      return Result.new("unchanged", derived, comparison.notes) if current == text

      File.write(FILE, text)
      Result.new("written", derived, comparison.notes)
    end

    # Whether *drop* names a step (`Type#step`) the derived lock still has.
    def self.step?(derived : JSON::Any, drop : String) : Bool
      type, _, step = drop.partition('#')
      return false if step.empty?

      steps = derived["payloads"]?.try(&.[type]?).try(&.["steps"]?).try(&.as_a?) || return false
      steps.any?(&.["name"].as_s.==(step))
    end

    # `--check` and the types given with `--drop`.
    def self.options(args : Array(String)) : {Bool, Array(String)} | Failure
      args = args.dup
      check = !!args.delete("--check")
      drops = [] of String
      while index = args.index("--drop")
        drops << (args[index + 1]? || return Failure.usage("missing_value", "--drop needs the job type, as payloads.lock.json lists it."))
        args.delete_at(index, 2)
      end
      return Failure.usage("unexpected_argument", "'punch jobs:lock' takes --check and --drop TYPE.") unless args.empty?
      return Failure.usage("unexpected_argument", "--drop changes the lock; it does not go with --check.") if check && !drops.empty?

      {check, drops}
    end

    # The lock as the app's derivation build derives it.
    def self.derive(project : Project) : JSON::Any | Failure
      binary = project.derivation
      return binary if binary.is_a?(Failure)

      output, errors = IO::Memory.new, IO::Memory.new
      status = Process.run(binary, ["jobs:derive", "--json"], output: output, error: errors)
      return Failure.new("derive_failed", "#{binary} jobs:derive failed:\n#{errors}#{output}") unless status.success?

      JSON.parse(output.to_s)
    end
  end
end
