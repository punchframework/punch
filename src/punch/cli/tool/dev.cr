require "http/client"
require "./project"
require "../../bareknuckle"

module Punch::CLI
  # The development loop behind `punch dev`. Each round, in order:
  #
  # 1. applies pending migrations to the primary database in
  #    `PUNCH_STORAGE`, which rewrites `db/schema.sql` when it changes;
  # 2. regenerates the query files (`punch db:generate`) when the app has a
  #    schema;
  # 3. regenerates the translations (`punch i18n:generate`) when the app
  #    has locale files, and the require file (`punch requires:generate`)
  #    when it has `app/`;
  # 4. builds the app's first target, retrying a link failure once, unless
  #    only the contents of assets changed: a `punch dev` build
  #    (`-Dpunch_dev`) reads them from disk, and an open page reloads
  #    itself (`Punch::Dev`);
  # 5. restarts the app with `serve`, after the build succeeded. A failed
  #    step leaves the running app as it is.
  #
  # It builds with the fastest linker it finds (`linker`), keeping debug
  # information for backtraces, and with its own object cache
  # (`cache_directory`): Crystal keys the cache on the main file and drops
  # it when the link flags change, so sharing it with `punch check`'s
  # builds would make each start cold.
  #
  # Then it polls the files the build depends on and starts the next round
  # when one changes. Files the round itself wrote do not count.
  #
  # Each round is logged to `tmp/punch-dev/rounds.jsonl`
  # (`Bareknuckle::RoundLog`): the files that differ from the last build
  # with what a warm compiler would have needed for them, the compiler's
  # stage times, the modules it regenerated, and how long the app took to
  # answer `/up`. `punch dev:rounds` summarizes it.
  #
  # With `--bareknuckle` or `PUNCH_BAREKNUCKLE=on`, and once the daemon is
  # built (`punch bareknuckle:build`), the bareknuckle daemon builds the app
  # instead of `crystal build` (`Bareknuckle::Daemon`): a full build keeps
  # the typed program warm, and a round that only changed method bodies
  # takes the fast path, which types those methods again, generates only
  # their modules, and links. Anything else is a full build in a new daemon
  # process; without the daemon, `crystal build` as before. When the files
  # stay unchanged for `VERIFY_AFTER` after a fast round, a full build of
  # the same files runs in the background, and its code is compared with the
  # fast path's: a difference is logged and turns the fast path off until
  # `punch dev` restarts.
  class DevLoop
    # What a round reads: sources, queries, migrations, the column mapping,
    # the embedded credentials files and OpenAPI document, and the shard
    # files.
    WATCHED_DIRECTORIES = %w[src app db config]
    WATCHED_FILES       = %w[shard.yml shard.lock openapi.json]
    BINARY              = "tmp/punch-dev/app"
    # How long the files must stay unchanged after a fast round before
    # the verification build starts.
    VERIFY_AFTER = 5.seconds

    getter rounds = 0

    # The fastest linker the C compiler can use, for `-fuse-ld`: mold, then
    # lld, then gold. `nil` on macOS, whose linker is used as it is, and
    # where none is installed. Dropped for the session when a build with
    # it fails to link.
    @linker : String? = DevLoop.linker

    @app : Process?
    @built : Bareknuckle::Inputs? = nil
    # The daemon that made the running app, warm when it built it.
    @daemon : Bareknuckle::Daemon? = nil
    @warm = false
    # Why the daemon does not run, once known.
    @unavailable : String? = nil
    # Off after a verification build found a difference.
    @fast = true
    # Fast rounds not verified yet, the last one's number, and when it
    # ended.
    @unverified : {Int32, Time::Instant}? = nil
    @verification : Process? = nil
    # Where rounds are logged, fixed when the loop starts: the boot of a
    # round is timed in its own fiber, which may finish after the working
    # directory changed (in specs).
    @rounds_log : String = File.expand_path(Bareknuckle::RoundLog::ROUNDS)
    @stopped = Channel(Nil).new(1)
    @done = Channel(Nil).new
    @stopping = Atomic(Bool).new(false)

    # *poll* is how often the files are checked; *env* is passed to the app
    # (`PUNCH_TRACE=console` unless set); *bareknuckle* builds with the
    # daemon when it is built, which is opt-in (`Commands::Dev.bareknuckle?`).
    def initialize(@project : Project, @settings : AppConfig, @log : IO = STDERR,
                   @poll : Time::Span = 300.milliseconds, @env : Hash(String, String) = {} of String => String,
                   @bareknuckle : Bool = false)
    end

    # Runs rounds until `stop`; then stops the app and returns.
    def run : Nil
      snapshot = round(first: true)
      loop do
        select
        when @stopped.receive?
          break
        when timeout(@poll)
          current = DevLoop.snapshot
          if current == snapshot
            verify(snapshot)
            next
          end
          @verification.try { |process| process.terminate rescue nil }
          sleep 50.milliseconds # let an editor finish writing
          changed = (current.keys + snapshot.keys).uniq!.select { |path| current[path]? != snapshot[path]? }
          say "changed: #{changed.first(3).join(", ")}#{changed.size > 3 ? " and #{changed.size - 3} more" : ""}"
          snapshot = round(first: false)
        end
      end
      stop_app
      @verification.try { |process| process.terminate rescue nil }
      @daemon.try(&.stop)
      @done.send(nil)
    end

    # Ends `run`: stops the app and returns once it has exited.
    def stop : Nil
      return if @stopping.swap(true)

      @stopped.send(nil)
      @done.receive
    end

    # Whether the app process is running.
    def app_running? : Bool
      @app.try { |process| !process.terminated? } || false
    end

    # The modification time of every watched file.
    def self.snapshot : Hash(String, Time)
      files = {} of String => Time
      WATCHED_DIRECTORIES.each do |directory|
        next unless Dir.exists?(directory)
        Dir.glob("#{directory}/**/*") do |path|
          info = File.info?(path) || next
          files[path] = info.modification_time if info.file?
        end
      end
      WATCHED_FILES.each { |path| File.info?(path).try { |info| files[path] = info.modification_time } }
      files
    end

    # One round; returns the snapshot taken once it has written its files
    # and before it builds, so that the files it wrote do not start
    # another round, and a file saved during the build does.
    private def round(first : Bool) : Hash(String, Time)
      @rounds += 1
      started = Time.instant
      at = Time.utc
      return DevLoop.snapshot unless migrate && generate && translate && wire

      snapshot = DevLoop.snapshot
      inputs = Bareknuckle::Inputs.capture(snapshot.keys)
      edits = @built.try { |built| inputs.edits(built) } || [] of Bareknuckle::Edit
      round = {number: @rounds, first: first, at: at, edits: edits, build_seconds: 0.0, started: started}
      if !first && needs_no_build?(edits)
        @built = inputs
        say "no build needed: #{edits.map(&.path).first(3).join(", ")}#{edits.size > 3 ? " and #{edits.size - 3} more" : ""}" unless edits.empty?
        log_round(round, nil, nil, skipped: true)
      else
        build_and_restart(round, inputs)
      end
      snapshot
    end

    # Whether the running app already is what a build of the files would
    # be: nothing it compiled changed (only assets, which a `punch dev`
    # build reads from disk, or nothing at all).
    private def needs_no_build?(edits : Array(Bareknuckle::Edit)) : Bool
      !@built.nil? && app_running? && Bareknuckle::Inputs.tier(edits).none?
    end

    private def build_and_restart(round, inputs : Bareknuckle::Inputs) : Nil
      building = Time.instant
      build, way = build_app(round[:first], round[:edits], inputs)
      round = round.merge(build_seconds: (Time.instant - building).total_seconds)
      unless build
        say "the running app is unchanged; fix the error and save" if !round[:first] && app_running?
        return log_round(round, nil, nil, way: way)
      end

      @built = inputs
      @unverified = way.path == "fast" ? {round[:number], Time.instant} : nil
      process = restart
      say "#{round[:first] ? "started" : "restarted"} in #{(Time.instant - round[:started]).total_seconds.round(1)} s#{build.retried ? " (link retried)" : ""}: http://#{@settings.host}:#{@settings.port}"
      spawn { log_round(round, build, boot_seconds(process), way: way) }
    end

    private def log_round(round, build : Project::Build?, boot : Float64?, skipped : Bool = false, way : Way? = nil) : Nil
      stats = Bareknuckle::Stats.parse(build.try(&.output) || "")
      tier = round[:first] ? "first" : Bareknuckle::Inputs.tier(round[:edits]).to_s.underscore
      entry = Bareknuckle::RoundLog::Round.new(round[:number], round[:at], round[:edits], tier, !build.nil?, round[:build_seconds], stats, boot,
        (Time.instant - round[:started]).total_seconds, skipped, way.try(&.path), way.try(&.refused), way.try(&.modules))
      Bareknuckle::RoundLog.append(@rounds_log, entry)
      return unless build

      groups = stats.groups.map { |name, seconds| "#{name} #{seconds.round(1)}" }.join(", ")
      modules = stats.reuse == "some" ? "#{stats.reused}/#{stats.total} modules reused" : "#{stats.reuse} modules reused"
      via = way.try { |taken| taken.path == "fast" ? ", fast path" : taken.path == "bareknuckle" ? ", bareknuckle" : "" }
      say "round #{round[:number]} (#{tier}#{via}): build #{round[:build_seconds].round(1)} s (#{groups}; #{modules})#{boot ? ", up after #{boot.round(2)} s" : ""}"
    rescue ex : File::Error
      say "could not log the round: #{ex.message}"
    end

    # How long *process* takes to answer `/up`; `nil` when it does not
    # within 30 s, exits, or is replaced first. Runs in its own fiber, so
    # the loop goes on watching files.
    private def boot_seconds(process : Process) : Float64?
      started = Time.instant
      host = @settings.host.in?("0.0.0.0", "::", "") ? "127.0.0.1" : @settings.host
      until Time.instant - started > 30.seconds
        return if @app != process || process.terminated?

        begin
          return (Time.instant - started).total_seconds if ::HTTP::Client.get("http://#{host}:#{@settings.port}/up").success?
        rescue Socket::Error | IO::Error
        end
        sleep 20.milliseconds
      end
      nil
    end

    private def migrate : Bool
      return true unless Dir.exists?(Punch::Migrations::DIRECTORY)

      step("db:migrate", Commands::DbMigrate, [@settings.primary_database])
    end

    private def generate : Bool
      return true unless File.exists?(Punch::Migrations::SCHEMA)

      step("db:generate", Commands::DbGenerate, [] of String)
    end

    private def translate : Bool
      return true unless @project.name != "punch" && Commands::I18nGenerate.applies?(@project)

      step("i18n:generate", Commands::I18nGenerate, [] of String)
    end

    private def wire : Bool
      return true unless Commands::RequiresGenerate.applies?

      step("requires:generate", Commands::RequiresGenerate, [] of String)
    end

    # Runs a command in process; prints what it applied or wrote, and its
    # failure.
    private def step(name : String, command : Command.class, args : Array(String)) : Bool
      case outcome = command.new(TOOL_COMMANDS).run(args)
      in Report
        text = IO::Memory.new
        outcome.to_text(text)
        lines = text.to_s.lines.select { |line| line.starts_with?("Applied") || line.starts_with?("Wrote") || line.starts_with?("written") }
        say "#{name}: #{lines.join("\n  ")}" unless lines.empty?
        true
      in Failure
        say "#{name} failed: #{outcome.message}"
        false
      end
    end

    # How a round was built: `fast` (the daemon's fast path),
    # `bareknuckle` (a full build in the daemon) or `crystal`; why the fast
    # path did not apply; the modules it generated.
    record Way, path : String, refused : String? = nil, modules : Array(String)? = nil

    private def build_app(first : Bool, edits : Array(Bareknuckle::Edit), inputs : Bareknuckle::Inputs) : {Project::Build?, Way}
      say first ? "building #{@project.main}" : "rebuilding"
      build, way = fast(edits, inputs) || full(nil)
      if !build.success && (linker = @linker) && Project.link_failure?(build.output)
        say "linking with #{linker} failed; building with the default linker from now on"
        @linker = nil
        build, way = full(way.refused)
      end
      return {build, way} if build.success

      say "build failed:\n#{Bareknuckle::Stats.strip(build.output).rstrip}"
      {nil, way}
    end

    # The daemon's fast path, when the edits only changed Crystal files the
    # daemon can take; `nil` for a full build.
    private def fast(edits : Array(Bareknuckle::Edit), inputs : Bareknuckle::Inputs) : {Project::Build, Way}?
      daemon = @daemon
      return unless daemon && @warm && @fast && Bareknuckle::Inputs.tier(edits).fast?

      changed = edits.reject(&.tier.none?)
      return unless changed.all? { |edit| edit.path.ends_with?(".cr") && inputs.sources.has_key?(edit.path) }

      case patched = daemon.patch(changed.to_h { |edit| {File.expand_path(edit.path), inputs.sources[edit.path]} })
      in Bareknuckle::Daemon::Patched
        {Project::Build.new(true, patched.output), Way.new("fast", modules: patched.modules)}
      in Bareknuckle::Daemon::Refused
        say "bareknuckle: full build: #{patched.reason}"
        full(patched.reason)
      in Nil
        say "bareknuckle: the daemon stopped; full build"
        full("the daemon stopped")
      end
    end

    # A full build: in a new daemon process, which then keeps the program
    # warm, or with `crystal build` without one.
    private def full(refused : String?) : {Project::Build, Way}
      @daemon.try(&.stop)
      @daemon = nil
      @warm = false
      if @bareknuckle && @unavailable.nil?
        case daemon = Bareknuckle::Daemon.start(@project.main, DEV_FLAGS, "#{BINARY}.next", link_flags, DevLoop.cache_directory("bareknuckle"))
        in Bareknuckle::Daemon
          if built = daemon.build
            @daemon = daemon
            @warm = built.success
            return {Project::Build.new(built.success, built.output), Way.new("bareknuckle", refused)}
          end
          daemon.stop
          @unavailable = "stopped during a build"
          say "bareknuckle: the daemon stopped during a build; building with crystal build from now on"
        in String
          @unavailable = daemon
          say "bareknuckle: #{daemon}"
        end
      end
      {compile, Way.new("crystal", refused)}
    end

    # What a `punch dev` build defines; the bareknuckle daemon builds with
    # the same.
    DEV_FLAGS = ["-Dpunch_dev"]

    private def compile : Project::Build
      flags = ["--stats"] + DEV_FLAGS
      link_flags.try { |value| flags << "--link-flags=#{value}" }
      Project.build(@project.main, "#{BINARY}.next", flags, {"CRYSTAL_CACHE_DIR" => DevLoop.cache_directory})
    end

    private def link_flags : String?
      @linker.try { |linker| "-fuse-ld=#{linker}" }
    end

    # The verification build: once the files stayed as *snapshot* for
    # `VERIFY_AFTER` after a fast round, a full build of them with the
    # daemon's compiler (`bareknuckle build`) at the lowest priority, in
    # its own object cache; the daemon then compares that cache with its
    # own.
    private def verify(snapshot : Hash(String, Time)) : Nil
      round, ended = @unverified || return
      return if @verification || Time.instant - ended < VERIFY_AFTER
      daemon = @daemon || return

      @unverified = nil
      cache = DevLoop.cache_directory("verify")
      args = ["build", "--main", @project.main, "--output", "#{BINARY}.verify"] + DEV_FLAGS.flat_map { |flag| ["-D", flag.lchop("-D")] }
      link_flags.try { |value| args.concat(["--link-flags", value]) }
      args = ["-n", "19", Bareknuckle::Daemon::BINARY] + args
      output = IO::Memory.new
      process = Process.new("nice", args, env: Bareknuckle::Daemon.env(cache), output: output, error: output)
      @verification = process
      spawn do
        status = process.wait
        @verification = nil
        File.delete?("#{BINARY}.verify")
        # Changed files, or a newer daemon, make the comparison moot.
        next unless status.success? && DevLoop.snapshot == snapshot && @daemon == daemon

        mismatches = daemon.verify(cache) || next
        Bareknuckle::RoundLog.append(Bareknuckle::RoundLog::VERIFY, {round: round, at: Time.utc.to_rfc3339, mismatches: mismatches})
        if mismatches.empty?
          say "bareknuckle: verified round #{round} against a full build"
        else
          @fast = false
          say "bareknuckle: the fast path differs from a full build in round #{round} (#{mismatches.first(3).join("; ")}); fast path off until punch dev restarts"
        end
      end
    rescue ex : IO::Error | File::Error
      say "bareknuckle: no verification build: #{ex.message}"
    end

    # See `@linker`.
    def self.linker : String?
      {% if flag?(:darwin) %}
        nil
      {% else %}
        {"mold" => "mold", "lld" => "ld.lld", "gold" => "ld.gold"}.each do |name, executable|
          return name if Process.find_executable(executable)
        end
        nil
      {% end %}
    end

    # Where `punch dev`'s builds keep Crystal's object cache: beside
    # Crystal's own (`CRYSTAL_CACHE_DIR`, or `crystal` in the user's cache
    # directory), with `-punch-dev` appended, and *suffix* for the
    # daemon's builds.
    def self.cache_directory(suffix : String? = nil) : String
      base = ENV["CRYSTAL_CACHE_DIR"]?.presence || File.join(ENV["XDG_CACHE_HOME"]?.presence || File.join(Path.home.to_s, ".cache"), "crystal")
      "#{base.rstrip('/')}-punch-dev#{suffix.try { |value| "-#{value}" }}"
    end

    private def restart : Process
      stop_app
      File.rename("#{BINARY}.next", BINARY)
      env = {"PUNCH_TRACE" => ENV["PUNCH_TRACE"]? || "console", "PUNCH_ENV" => ENV["PUNCH_ENV"]?.presence || "development"}.merge(@env)
      @app = process = Process.new(BINARY, ["serve"], env: env, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      spawn watch(process)
      process
    end

    private def watch(process : Process) : Nil
      status = process.wait
      return if @app != process # replaced or stopped on purpose

      say "the app exited (#{status.exit_reason.to_s.underscore}#{status.normal_exit? ? " #{status.exit_code}" : ""}); waiting for changes"
    end

    # SIGTERM, the app's graceful shutdown; SIGKILL after 30 s.
    private def stop_app : Nil
      process = @app || return
      @app = nil
      return if process.terminated?

      process.signal(Signal::TERM) rescue nil
      deadline = Time.instant + 30.seconds
      until process.terminated? || Time.instant > deadline
        sleep 20.milliseconds
      end
      process.signal(Signal::KILL) rescue nil unless process.terminated?
    end

    private def say(message : String) : Nil
      @log.puts "punch dev: #{message}"
      @log.flush
    end
  end

  module Commands
    # `punch dev`: the development loop (`DevLoop`). Runs until SIGINT or
    # SIGTERM. The app's own output, including the trace of each request
    # (`PUNCH_TRACE=console`), goes to the terminal.
    class Dev < Command
      command "dev", "Run the app and rebuild it on every change: migrate, regenerate queries, build, restart"

      def self.json? : Bool
        false
      end

      struct Stopped
        include Report

        def to_text(io : IO) : Nil
        end

        def to_json(json : JSON::Builder) : Nil
          json.object { }
        end
      end

      # Whether the bareknuckle daemon builds: only when asked for, with
      # `--bareknuckle` or `PUNCH_BAREKNUCKLE=on`, until real sessions show
      # it pays for itself. Removes the flag from *args*.
      def self.bareknuckle?(args : Array(String), env : Hash(String, String) | ENV.class = ENV) : Bool
        flag = !args.delete("--bareknuckle").nil?
        flag || env["PUNCH_BAREKNUCKLE"]? == "on"
      end

      def run(args : Array(String)) : Report | Failure
        bareknuckle = Dev.bareknuckle?(args)
        if failure = no_arguments(args)
          return failure
        end

        project = Project.load
        return project if project.is_a?(Failure)

        settings = Config.settings
        return settings if settings.is_a?(Failure)

        dev = DevLoop.new(project, settings, bareknuckle: bareknuckle)
        Process.on_terminate do |reason|
          spawn dev.stop if reason.interrupted? || reason.session_ended?
        end
        dev.run
        Stopped.new
      end
    end
  end
end
