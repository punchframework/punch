require "digest/sha256"
require "./project"
require "../../bareknuckle"

module Punch::CLI::Commands
  # `punch typecheck`: the compiler's type check of the app's first target
  # without code generation (`crystal build --no-codegen`), the fast inner
  # loop for a person or a coding agent: every error the compiler finds,
  # macros included, in a third of a build's time, and no binary. The
  # generated files it reads are made current first, as `punch dev` does:
  # queries (`db:generate`), translations (`i18n:generate`), and the
  # require file (`requires:generate`). Where `punch dev` has run (its
  # `tmp/punch-dev/` exists), each run's stage times go to
  # `tmp/punch-dev/typecheck.jsonl` (`Bareknuckle::RoundLog`); elsewhere a
  # type check leaves no file behind.
  #
  # While `punch dev` builds with the bareknuckle daemon, the type check
  # asks the daemon instead (`Bareknuckle::Daemon.status`): once a round
  # has built the files as they are on disk, its result is the answer,
  # usually within a second of the save. It waits up to `WAIT` for that
  # round, then type-checks as above. `punch dev`'s builds define
  # `punch_dev`, which only changes how assets are served.
  class Typecheck < Command
    command "typecheck", "Type-check the app without building it (crystal build --no-codegen), after regenerating queries, translations, and requires"

    # How long to wait for `punch dev` to build the files on disk.
    WAIT = 120.seconds

    struct Result
      include Report

      # *source*: `punch dev` when its daemon answered.
      def initialize(@main : String, @seconds : Float64, @source : String? = nil)
      end

      def to_text(io : IO) : Nil
        io.puts "#{@main} type-checks (#{@seconds.round(1)} s#{@source.try { |source| ", from #{source}" }})."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "main", @main
          json.field "seconds", @seconds.round(2)
          json.field "source", @source if @source
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      project = Project.load
      return project if project.is_a?(Failure)
      if problem = generate(project)
        return problem
      end

      at = Time.utc
      started = Time.instant
      if answer = from_daemon(project, started)
        return answer
      end
      check = Project.typecheck(project.main, ["--stats"])
      seconds = (Time.instant - started).total_seconds
      log(at, check, seconds)
      return Failure.new("typecheck_failed", "Type-checking #{project.main} failed:\n#{Bareknuckle::Stats.strip(check.output)}") unless check.success

      Result.new(project.main, seconds)
    end

    # The answer of `punch dev`'s daemon, once it has built the files on
    # disk; `nil` without a daemon, or when it has not within `WAIT`.
    private def from_daemon(project : Project, started : Time::Instant) : (Report | Failure)?
      missing = 0
      until Time.instant - started > WAIT
        status = Bareknuckle::Daemon.status
        # Between two daemons, when a round starts a new one.
        unless status
          return if (missing += 1) > 5 || !File.exists?(Bareknuckle::Daemon::SOCKET)
          sleep 200.milliseconds
          next
        end
        files, error = status
        current = files.all? { |path, digest| File.file?(path) && Digest::SHA256.hexdigest(File.read(path)) == digest }
        if current
          seconds = (Time.instant - started).total_seconds
          log_daemon(error.nil?, seconds)
          return Failure.new("typecheck_failed", "Type-checking #{project.main} failed (punch dev's build):\n#{error.strip}") if error
          return Result.new(project.main, seconds, "punch dev")
        end
        sleep 200.milliseconds
      end
      nil
    end

    private def log_daemon(success : Bool, seconds : Float64) : Nil
      return unless Dir.exists?(Bareknuckle::RoundLog::DIRECTORY)

      Bareknuckle::RoundLog.append(Bareknuckle::RoundLog::TYPECHECK, {at: Time.utc.to_rfc3339, success: success, seconds: seconds.round(3), source: "punch dev"})
    rescue File::Error
    end

    private def log(at : Time, check : Project::Build, seconds : Float64) : Nil
      return unless Dir.exists?(Bareknuckle::RoundLog::DIRECTORY)

      stats = Bareknuckle::Stats.parse(check.output)
      entry = {at: at.to_rfc3339, success: check.success, seconds: seconds.round(3), stats: stats}
      Bareknuckle::RoundLog.append(Bareknuckle::RoundLog::TYPECHECK, entry)
    rescue File::Error
      # A read-only checkout still type-checks.
    end

    # The files the type check reads, current; the first failure.
    private def generate(project : Project) : Failure?
      steps = [] of {Command.class, Array(String)}
      steps << {DbGenerate, [] of String} if File.exists?(Punch::Migrations::SCHEMA)
      steps << {I18nGenerate, [] of String} if project.name != "punch" && I18nGenerate.applies?(project)
      steps << {RequiresGenerate, [] of String} if RequiresGenerate.applies?
      steps.each do |command, args|
        outcome = command.new(TOOL_COMMANDS).run(args)
        return outcome if outcome.is_a?(Failure)
      end
      nil
    end
  end
end
