require "./project"
require "../../bareknuckle"

module Punch::CLI::Commands
  # `punch check`: every check CI runs, the same on a laptop. Each step runs
  # when the project has what it checks, and all of them run even after one
  # fails, so one run reports everything:
  #
  # | Step | Does | When |
  # |---|---|---|
  # | `format` | `crystal tool format --check` | always, on `src`, `spec`, `app`, `db`, `tools` |
  # | `schema` | `punch db:schema --check` | `db/migrations` exists |
  # | `migrations` | `punch db:cost --check`: no unacknowledged rebuild in a migration `--base` does not have (all without one) | `db/migrations` exists |
  # | `punchtables` | Punch's own tables in `db/schema.sql` (outbox, job steps, idempotency keys, webhooks, uploads, auth, roles) have the columns this Punch expects; names the migration | `db/schema.sql` has one of them |
  # | `queries` | `punch db:generate --check` | `db/schema.sql` exists, or in Punch itself |
  # | `explain` | `punch db:explain --check`: no full scan or sort a query does not accept | `queries` passed and `db/schema.sql` exists |
  # | `i18n` | `punch i18n:generate --check`: current file, no gaps between locales, a message for every code | `config/locales` exists, and in Punch itself |
  # | `requires` | `punch requires:generate --check`: `app/requires.gen.cr` requires every file under `app/`, each of a known kind | `app` exists |
  # | `unreached` | every `app/**/*.cr` and `db/*.cr` but `db/seeds.cr` is in some target's require list (`crystal tool dependencies`): a file nothing requires compiles away silently | `app` or `db` has Crystal files |
  # | `docs` | `punch docs:check`: guide code blocks quoted, failing, or illustrative and current; quoted messages current; links resolve; every page indexed | in Punch itself |
  # | `lint` | Ameba with Punch's rules | always |
  # | `build` | every target, warnings as errors, statistics in `tmp/build-stats/` | always |
  # | `creds` | key files are neither committed nor unignored; every encrypted file with a key file decrypts; the built app's `creds:check` passes for those environments | `config/credentials` exists |
  # | `limits` | every Command without a required user is rate limited or exempt | in Punch apps, after `build` |
  # | `policies` | every operation has a policy or is public | in Punch apps, after `build` |
  # | `events` | every event is published by an operation | in Punch apps, after `build` |
  # | `webhooks` | lists inbound webhook providers that do not verify their deliveries; never fails | in Punch apps with providers, after `build` |
  # | `jobs` | every recurring job's schedule parses | in Punch apps, after `build` |
  # | `payloads` | `punch jobs:lock --check`, then the lock against `--base`'s with the same rules | `payloads.lock.json` exists, or the app has job types of its own |
  # | `openapi` | `punch openapi --check`, then `openapi:diff` against `--base` | `openapi.json` exists |
  # | `specs` | the specs built as one binary (as `crystal spec` would), warnings as errors, then run with `CRYSTAL_WORKERS` threads (4 by default) | `spec` exists |
  # | `nocache` | the specs again with `PUNCH_CACHE=off`: the app must be correct with an empty cache | `specs` passed, in apps (not Punch itself) |
  class Check < Command
    command "check", "Run every check CI runs: format, schema, migrations, queries, query plans, translations, lint, build, credentials, limits, policies, events, jobs, payloads, OpenAPI, specs (also with the cache off); --base REF for the OpenAPI and payload diffs"

    FORMAT_DIRECTORIES = %w[src spec app db tools]
    BUILD_STATS        = "tmp/build-stats"
    AMEBA_DIRECTORY    = "tmp/punch-check"
    SPEC_DIRECTORY     = "tmp/punch-check/specs"

    enum Status
      Passed
      Failed
      Skipped
    end

    record Step, name : String, status : Status, seconds : Float64, detail : String do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "name", name
          json.field "status", status.to_s.downcase
          json.field "seconds", seconds.round(2)
          json.field "detail", detail
        end
      end
    end

    struct Result
      include Report

      getter steps : Array(Step)

      def initialize(@steps : Array(Step))
      end

      # One line: each step's own line went to stderr as it finished.
      def to_text(io : IO) : Nil
        passed = @steps.count(&.status.passed?)
        io.puts "All checks passed: #{passed} passed, #{@steps.size - passed} skipped, #{@steps.sum(&.seconds).round(1)} s."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "steps", @steps }
      end
    end

    # The step's line in the summary.
    def self.line(step : Step) : String
      detail = step.status.failed? ? "" : step.detail.lines.first?.try { |first| "  #{first}" } || ""
      "#{step.status.to_s.downcase.ljust(7)} #{step.name.ljust(10)} #{step.seconds.round(1).to_s.rjust(6)} s#{detail}"
    end

    # Where a line per finished step goes, for people; never with --json.
    property progress : IO? = STDERR

    def run(args : Array(String)) : Report | Failure
      base = nil
      if index = args.index("--base")
        base = args[index + 1]? || return Failure.usage("missing_argument", "--base needs a Git revision, such as origin/main.")
        args.delete_at(index, 2)
      end
      if failure = no_arguments(args)
        return failure
      end

      project = Project.load
      return project if project.is_a?(Failure)

      @progress = nil if json_output?

      # OpenAPI and the payload lock come from one derivation build.
      Project.reuse_derivation = true
      steps = begin
        run_steps(project, base)
      ensure
        Project.reuse_derivation = false
      end
      failed = steps.select(&.status.failed?)
      return Result.new(steps) if failed.empty?

      message = String.build do |io|
        io << failed.size << (failed.size == 1 ? " check" : " checks") << " failed: " << failed.join(", ", &.name)
        failed.each { |step| io << "\n\n== " << step.name << '\n' << step.detail.rstrip }
      end
      Failure.new("check_failed", message, details: JSON.parse({steps: steps}.to_json))
    end

    # Every step, in order; each runs when the project has what it checks.
    private def run_steps(project : Project, base : String?) : Array(Step)
      steps = [] of Step
      steps << step("format") { format }
      schema_steps(steps, base)
      steps << step("i18n") { translations(project) }
      steps << step("requires") { in_process(RequiresGenerate, ["--check"]) if RequiresGenerate.applies? }
      steps << step("unreached") { unreached(project) }
      steps << step("docs") { in_process(DocsCheck, [] of String) if DocsCheck.applies? }
      steps << step("lint") { lint }
      steps << step("build") { build(project) }
      built = steps.last.status.passed?
      steps << step("creds") { credentials(project, built) if Dir.exists?(Punch::Credentials::DIRECTORY) }
      # Asked of the built app's binary, which only Punch apps have.
      asked = built && project.punch_app?
      asked_steps(steps, project, asked)
      steps << step("payloads") { payloads(base) if asked && (File.exists?(JobsLock::FILE) || @own_jobs) }
      steps << step("openapi") { openapi(base) if File.exists?(OpenAPIWrite::FILE) }
      steps << step("specs") { specs if Dir.exists?("spec") }
      # Only after passing specs, and only in apps: Punch's own specs test
      # the cache itself.
      passed = steps.last.status.passed?
      steps << step("nocache") { specs({"PUNCH_CACHE" => "off"}) if passed && project.name != "punch" }
      steps
    end

    # The steps on migrations, the schema, and the queries generated from it.
    private def schema_steps(steps : Array(Step), base : String?) : Nil
      steps << step("schema") { in_process(DbSchema, ["--check"]) if Dir.exists?(Punch::Migrations::DIRECTORY) }
      steps << step("migrations") { migration_costs(base) if Dir.exists?(Punch::Migrations::DIRECTORY) }
      steps << step("punchtables") { punch_tables if File.exists?(Punch::Migrations::SCHEMA) }
      steps << step("queries") { in_process(DbGenerate, ["--check"]) if File.exists?(Punch::Migrations::SCHEMA) || File.exists?(QueryGen::Composites::OWN_PATH) }
      queries = steps.last.status.passed?
      steps << step("explain") { in_process(DbExplain, ["--check"]) if queries && File.exists?(Punch::Migrations::SCHEMA) }
    end

    # The steps asked of the built app's binary.
    private def asked_steps(steps : Array(Step), project : Project, asked : Bool) : Nil
      steps << step("limits") { rate_limits(project) if asked }
      steps << step("policies") { policies(project) if asked }
      steps << step("events") { events(project) if asked }
      steps << step("webhooks") { webhooks(project) if asked }
      steps << step("jobs") { jobs(project) if asked }
      steps << step("boot") { boot_migrations(project) if asked && Dir.exists?(Punch::Migrations::DIRECTORY) }
    end

    # The app's binary carries its migrations (`Punch.migrations`), so a
    # deploy migrates at boot without a source tree (`docs/deployment.md`).
    private def boot_migrations(project : Project) : {Bool, String}
      path = File.tempname("punch-boot", ".db")
      ok, output = command(File.join("bin", project.targets.first[0]), ["db:status", path, "--json"])
      return {false, output} unless ok

      status = JSON.parse(output)
      unless status["source"] == "binary"
        return {false, "The app's binary does not carry its migrations, so it cannot migrate at boot. Declare them once in app/setup.cr: Punch.migrations \"../db/migrations\" (lib/punch/docs/deployment.md)."}
      end

      {true, "#{status["migrations"].as_a.size} migrations embedded, applied at boot"}
    end

    # Runs one step: the block returns `nil` to skip, or whether it passed
    # and what to show.
    private def step(name : String, & : -> {Bool, String}?) : Step
      started = Time.instant
      outcome = yield
      seconds = (Time.instant - started).total_seconds
      step = case outcome
             when nil then Step.new(name, :skipped, seconds, "nothing to check")
             else          Step.new(name, outcome[0] ? Status::Passed : Status::Failed, seconds, outcome[1])
             end
      @progress.try { |io| io.puts Check.line(step); io.flush }
      step
    end

    # Every file of the app that no target requires: its routes, types, or
    # queries do not exist, and nothing says so. The compiler lists what a
    # main file reaches (`crystal tool dependencies`), so this takes under a
    # second. Skipped without app code.
    private def unreached(project : Project) : {Bool, String}?
      # The seed is a main file of its own (`punch db:seed`).
      files = (Dir.glob("app/**/*.cr") + Dir.glob("db/*.cr")).reject(Commands::DbSeed::SEEDS).sort!
      return if files.empty?

      reached = Set(String).new
      project.targets.each do |_, main|
        ok, output = command("crystal", ["tool", "dependencies", "-f", "flat", "--no-color", main])
        return {false, "Cannot list what #{main} requires:\n#{output}"} unless ok

        output.each_line { |line| reached << File.expand_path(line.strip) unless line.blank? }
      end
      Check.unreached(files, reached)
    end

    # The rule of the `unreached` step: *files* that are not in *reached*
    # (absolute paths).
    def self.unreached(files : Array(String), reached : Set(String)) : {Bool, String}
      missing = files.reject { |file| reached.includes?(File.expand_path(file)) }
      unless missing.empty?
        lines = missing.map { |file| "  #{file}: require it (lib/punch/docs/structure.md)" }
        return {false, "Files that no target requires; the compiler ignores them, so their routes, types, or queries do not exist:\n#{lines.join('\n')}"}
      end
      {true, "#{files.size} files, all required"}
    end

    # Punch's own tables as the app's schema has them, against what the
    # linked Punch needs: `serve` checks the same at boot (docs/tooling.md).
    private def punch_tables : {Bool, String}?
      found = PunchTables.columns(File.read(Punch::Migrations::SCHEMA))
      problems = PunchTables.drift(found)
      return {false, "db/schema.sql differs from the tables this Punch expects:\n  #{problems.join("\n  ")}"} unless problems.empty?

      present = PunchTables.present(found)
      {true, present.empty? ? "no Punch tables in the schema" : "#{present.join(", ")} as Punch expects"}
    rescue ex : Punch::Migrations::Error
      {false, "db/schema.sql does not load: #{ex.message}"}
    end

    private def translations(project : Project) : {Bool, String}?
      in_process(I18nGenerate, ["--check"]) if I18nGenerate.applies?(project)
    end

    private def format : {Bool, String}
      directories = FORMAT_DIRECTORIES.select { |directory| Dir.exists?(directory) }
      return {true, "no source directories"} if directories.empty?

      ok, output = command("crystal", ["tool", "format", "--check", "--no-color"] + directories)
      {ok, ok ? directories.join(", ") : output}
    end

    private def in_process(command : Command.class, args : Array(String)) : {Bool, String}
      case outcome = command.new(TOOL_COMMANDS).run(args)
      in Report  then {true, String.build { |io| outcome.to_text(io) }}
      in Failure then {false, outcome.message}
      end
    end

    # Ameba with Punch's rules. The Punch repository builds it from
    # `tools/ameba.cr`; an app from `punch/ameba` and its own Ameba, a
    # development dependency.
    private def lint : {Bool, String}
      if File.exists?("tools/ameba.cr")
        source, binary = "tools/ameba.cr", "bin/ameba"
        inputs = ["tools/ameba.cr", "src/punch/ameba.cr", "src/punch/ameba", "lib/ameba"]
      else
        unless Dir.exists?("lib/ameba")
          return {false, "Ameba is not installed. Add it to development_dependencies in shard.yml (ameba: github: crystal-ameba/ameba, version: ~> 1.7.0) and run 'shards install'."}
        end

        Dir.mkdir_p(AMEBA_DIRECTORY)
        source, binary = File.join(AMEBA_DIRECTORY, "ameba.cr"), File.join(AMEBA_DIRECTORY, "ameba")
        File.write(source, %(# Written by punch check: Ameba with Punch's rules.\nrequire "punch/ameba"\nrequire "ameba/cli"\n))
        inputs = ["lib/ameba", "lib/punch/src/punch/ameba.cr", "lib/punch/src/punch/ameba"]
      end
      if stale?(binary, inputs)
        build = Project.build(source, binary, ["--release", "--no-debug"])
        return {false, "Building Ameba failed:\n#{build.output}"} unless build.success
      end
      # Without a configuration of its own, Ameba would also inspect tmp/.
      paths = File.exists?(".ameba.yml") ? [] of String : FORMAT_DIRECTORIES.select { |directory| Dir.exists?(directory) }
      command(binary, ["--no-color"] + paths)
    end

    # Whether *binary* is missing or older than a file under *inputs*.
    private def stale?(binary : String, inputs : Array(String)) : Bool
      built = File.info?(binary).try(&.modification_time) || return true
      inputs.any? do |input|
        next false unless File.exists?(input)
        next File.info(input).modification_time > built unless File.directory?(input)
        Dir.glob("#{input}/**/*.cr").any? { |path| File.info(path).modification_time > built }
      end
    end

    # Every target into `bin/`, through a temporary file, so a running
    # binary (this one, in the Punch repository) is replaced, not
    # overwritten. Records the compiler's statistics per commit.
    private def build(project : Project) : {Bool, String}
      revision = self.revision
      Dir.mkdir_p(BUILD_STATS)
      summary = [] of String
      project.targets.each do |name, main|
        started = Time.instant
        output = File.join("bin", name)
        build = Project.build(main, "#{output}.next", ["--stats", "--warnings", "all", "--error-on-warnings"])
        return {false, "Building #{main} failed:\n#{build.output}"} unless build.success

        File.rename("#{output}.next", output)
        seconds = (Time.instant - started).total_seconds.round(1)
        if revision
          File.write(File.join(BUILD_STATS, "#{revision}-#{name}.txt"), build.output.gsub(/.*\r/, ""))
          File.open(File.join(BUILD_STATS, "history.tsv"), "a") do |file|
            file.puts [Time.utc.to_rfc3339, revision, name, Crystal::VERSION, "#{seconds}s"].join('\t')
          end
        end
        summary << "#{output} (#{seconds} s#{build.retried ? ", link retried" : ""})"
      end
      {true, summary.join(", ")}
    end

    # Key files must never reach the repository; every file that can be
    # opened here must open and satisfy the app's declared type.
    private def credentials(project : Project, built : Bool) : {Bool, String}
      directory = Punch::Credentials::DIRECTORY
      problems = [] of String
      keys = Dir.glob("#{directory}/*.key").sort!
      if tracked = git("ls-files", "--", directory)
        tracked.lines.select(&.ends_with?(".key")).each do |path|
          problems << "#{path} is committed. Remove it (git rm --cached #{path}), then run 'punch creds:rekey': the key in the history is no longer secret."
        end
        keys.each do |path|
          next if git("check-ignore", "-q", path)
          problems << "#{path} is not ignored by git; add #{CredsInit::GITIGNORE} to .gitignore."
        end
      end
      checked = [] of String
      Dir.glob("#{directory}/*.yml.enc").sort!.each do |file|
        environment = File.basename(file, ".yml.enc")
        next unless File.exists?(Punch::Credentials.key_file(environment))
        key = Punch::Credentials::MasterKey.parse(File.read(Punch::Credentials.key_file(environment)), Punch::Credentials.key_file(environment))
        next problems << key if key.is_a?(String)

        case text = Punch::Credentials::EncryptedFile.decrypt(File.read(file), key)
        in Punch::Credentials::EncryptedFile::Error then problems << text.message(file, key)
        in String
          if problem = Punch::Credentials::YAMLTree.parse(text, file).as?(String)
            problems << problem
          elsif built
            ok, output = command(File.join("bin", project.targets.first[0]), ["creds:check", "--env", environment],
              {"PUNCH_MASTER_KEY" => key.to_text})
            ok ? checked << environment : problems << output.strip.lchop("#{project.targets.first[0]}: ")
          end
        end
      end
      return {false, problems.join("\n")} unless problems.empty?

      {true, checked.empty? ? "#{keys.size} key files ignored; no environment to check" : "checked #{checked.join(", ")}"}
    end

    # Every Command that runs without a signed-in user has a rate limit or
    # says why not: asked of the app's binary (`routes`).
    private def rate_limits(project : Project) : {Bool, String}
      ok, output = command(File.join("bin", project.targets.first[0]), ["routes", "--json"])
      return {false, output} unless ok

      Check.rate_limits(JSON.parse(output)["routes"].as_a)
    end

    # The rule of the `limits` step over the app's route table.
    def self.rate_limits(routes : Array(JSON::Any)) : {Bool, String}
      commands = routes.select { |route| route["kind"] == "command" && route["actor"] != "required" }
      open = commands.select { |route| route["rate_limits"].as_a.empty? && !route["rate_limit_exempt"]?.try(&.as_s?) }
      unless open.empty?
        lines = open.map { |route| "  #{route["method"]} #{route["path"]}  #{route["operation"]}" }
        return {false, "Commands that run without a signed-in user need a rate limit, @[Punch::RateLimit(...)], " \
                       "or @[Punch::RateLimitExempt(\"reason\")] (lib/punch/docs/rate-limits.md):\n#{lines.join('\n')}"}
      end
      limited = routes.count { |route| !route["rate_limits"].as_a.empty? }
      {true, "#{commands.size} commands without a required user limited or exempt; #{limited} operations limited"}
    end

    # Every operation declares a policy or says it is public: asked of the
    # app's binary (`routes`).
    private def policies(project : Project) : {Bool, String}
      ok, output = command(File.join("bin", project.targets.first[0]), ["routes", "--json"])
      return {false, output} unless ok

      Check.policies(JSON.parse(output)["routes"].as_a)
    end

    # The rule of the `policies` step over the app's route table.
    def self.policies(routes : Array(JSON::Any)) : {Bool, String}
      open = routes.select { |route| route["policy"]?.try(&.as_s?).nil? && route["public"]?.try(&.as_bool?) != true }
      unless open.empty?
        lines = open.map { |route| "  #{route["method"]} #{route["path"]}  #{route["operation"]}" }
        return {false, "Operations need a policy, @[Punch::Authorize(Policy)], or @[Punch::Public] (lib/punch/docs/authorization.md):\n#{lines.join('\n')}"}
      end
      public = routes.count { |route| route["public"]?.try(&.as_bool?) == true }
      {true, "#{routes.size - public} operations with a policy, #{public} public"}
    end

    # The providers that do not verify their deliveries, so that nobody adds
    # one unnoticed: listed, never failing. Skipped without providers.
    private def webhooks(project : Project) : {Bool, String}?
      ok, output = command(File.join("bin", project.targets.first[0]), ["webhooks", "--json"])
      return {false, output} unless ok

      Check.webhooks(JSON.parse(output)["providers"].as_a)
    end

    # The rule of the `webhooks` step.
    def self.webhooks(providers : Array(JSON::Any)) : {Bool, String}?
      return if providers.empty?

      open = providers.select(&.["verify"].==("none")).map(&.["name"].as_s)
      return {true, "#{providers.size} providers, all verify their deliveries"} if open.empty?

      {true, "#{providers.size} providers; not verifying their deliveries (verify: :none): #{open.join(", ")}"}
    end

    # Every event has a publisher: asked of the app's binary (`events`).
    private def events(project : Project) : {Bool, String}
      ok, output = command(File.join("bin", project.targets.first[0]), ["events", "--json"])
      return {false, output} unless ok

      Check.events(JSON.parse(output)["events"].as_a)
    end

    # The rule of the `events` step over the app's event graph: an event no
    # operation publishes is dead, and so are its subscribers. Punch's own
    # events (`Punch::Auth::SignInSucceeded`) are published by Punch's operations,
    # which an app may not use: they count only when a subscriber of the
    # app's own listens.
    def self.events(events : Array(JSON::Any)) : {Bool, String}
      dead = events.select do |node|
        next false unless node["publishers"].as_a.empty?
        !node["event"].as_s.starts_with?("Punch::") || node["subscribers"].as_a.any? { |subscriber| !subscriber["subscriber"].as_s.starts_with?("Punch::") }
      end
      unless dead.empty?
        lines = dead.map do |node|
          subscribers = node["subscribers"].as_a.map(&.["subscriber"].as_s)
          "  #{node["event"]}#{subscribers.empty? ? "" : " (subscribers: #{subscribers.join(", ")})"}"
        end
        return {false, "Events that no operation publishes; publish them from a Command (`events : Punch::Events(...)` in its `call`) or delete them (lib/punch/docs/events.md):\n#{lines.join('\n')}"}
      end
      subscribers = events.sum(&.["subscribers"].as_a.size)
      {true, "#{events.size} events published, #{subscribers} subscriptions"}
    end

    # Every recurring job's schedule parses: asked of the app's binary
    # (`jobs:types`), which fails otherwise.
    private def jobs(project : Project) : {Bool, String}
      ok, output = command(File.join("bin", project.targets.first[0]), ["jobs:types", "--json"])
      unless ok
        message = (JSON.parse(output)["error"]["message"].as_s rescue output)
        return {false, message}
      end
      types = JSON.parse(output)["types"].as_a
      @own_jobs = types.any? { |type| !type["type"].as_s.starts_with?("Punch::") }
      {true, "#{types.size} job types, #{types.count { |type| !type["schedule"].raw.nil? }} recurring"}
    end

    # Whether the app has job types of its own, beyond Punch's: then it
    # needs a payload lock (`jobs` step).
    @own_jobs = false
    @spec_binary : String?

    # The payload lock is current, and every change since *base* is one
    # stored payloads can follow.
    private def payloads(base : String?) : {Bool, String}
      ok, detail = in_process(JobsLock, ["--check"])
      return {ok, detail} unless ok

      detail = detail.lines.first.strip
      base ||= %w[origin/main main].find { |ref| git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}") }
      return {true, "#{detail}; no base revision to compare with"} unless base

      old = git("show", "#{base}:./#{JobsLock::FILE}") || return {true, "#{detail}; #{base} has no #{JobsLock::FILE}"}
      comparison = Punch::Payloads::Lock.new(JSON.parse(old), JSON.parse(File.read(JobsLock::FILE)), removals: true)
      return {true, "#{detail}; against #{base}: #{comparison.notes.empty? ? "unchanged" : comparison.notes.join("; ")}"} if comparison.ok?

      {false, "#{JobsLock::FILE} against #{base}:\n  #{comparison.problems.join("\n  ")}#{comparison.ways_out}"}
    rescue ex : JSON::ParseException
      {false, "#{JobsLock::FILE} at #{base} does not parse: #{ex.message}"}
    end

    # Every migration that *base* does not have is checked for rebuilds
    # nobody acknowledged; without a base revision, all are.
    private def migration_costs(base : String?) : {Bool, String}
      base ||= %w[origin/main main].find { |ref| git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}") }
      in_process(DbCost, base ? ["--check", "--base", base] : ["--check"])
    end

    private def openapi(base : String?) : {Bool, String}
      ok, detail = in_process(OpenAPIWrite, ["--check"])
      return {ok, detail} unless ok

      base ||= %w[origin/main main].find { |ref| git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}") }
      return {true, "#{detail.strip}; no base revision to diff against"} unless base

      old = git("show", "#{base}:./#{OpenAPIWrite::FILE}") || return {true, "#{detail.strip}; #{base} has no #{OpenAPIWrite::FILE}"}
      path = File.tempname("punch-openapi-base", ".json")
      File.write(path, old)
      begin
        ok, diff = in_process(OpenAPIDiff, [path, OpenAPIWrite::FILE])
        {ok, "#{detail.strip}; against #{base}: #{diff.strip}"}
      ensure
        File.delete?(path)
      end
    end

    # Builds the specs once, then runs the binary: `crystal spec` keeps its
    # compiler (over 4 GB for Punch's own specs) alive while the specs run,
    # and specs that compile fixture apps then made the OOM killer end it,
    # failing the step although every example passed.
    private def specs(env : Hash(String, String) = {} of String => String) : {Bool, String}
      binary = @spec_binary ||= begin
        files = Dir.glob("spec/**/*_spec.cr").sort!
        return {false, "no spec files"} if files.empty?

        Dir.mkdir_p(SPEC_DIRECTORY)
        path = File.join(SPEC_DIRECTORY, "specs")
        started = Time.instant
        built, output = command("crystal", ["build", "--stats", "--warnings", "all", "--error-on-warnings", "--no-color", "-o", path] + files)
        return {false, Bareknuckle::Stats.strip(output)} unless built

        record_spec_stats(output, (Time.instant - started).total_seconds.round(1))

        path
      end
      workers = ENV["CRYSTAL_WORKERS"]? || "4"
      env = env.merge({"CRYSTAL_WORKERS" => workers})
      ok, output = command(binary, ["--no-color"], env)
      summary = output.lines.find(&.matches?(/\d+ examples?, /)) || ""
      {ok, ok ? "#{summary.strip} (#{env.join(" ") { |key, value| "#{key}=#{value}" }})" : output}
    end

    # The spec build's statistics beside the app's, per commit.
    private def record_spec_stats(output : String, seconds : Float64) : Nil
      revision = self.revision || return
      Dir.mkdir_p(BUILD_STATS)
      File.write(File.join(BUILD_STATS, "#{revision}-specs.txt"), output.gsub(/.*\r/, ""))
      File.open(File.join(BUILD_STATS, "history.tsv"), "a") do |file|
        file.puts [Time.utc.to_rfc3339, revision, "specs", Crystal::VERSION, "#{seconds}s"].join('\t')
      end
    end

    # The short commit, with `-dirty` when the working tree has changes;
    # `nil` outside a repository.
    private def revision : String?
      revision = git("rev-parse", "--short", "HEAD").try(&.strip) || return
      git("status", "--porcelain", "--", ".").try(&.presence) ? "#{revision}-dirty" : revision
    end

    private def command(name : String, args : Array(String), env : Hash(String, String)? = nil) : {Bool, String}
      output = IO::Memory.new
      status = Process.run(name, args, env: env, output: output, error: output)
      {status.success?, output.to_s}
    rescue ex : File::NotFoundError | IO::Error
      {false, "#{name}: #{ex.message}"}
    end

    # Git's output, or `nil` when it fails or this is no repository.
    private def git(*args : String) : String?
      output = IO::Memory.new
      status = Process.run("git", args.to_a, output: output, error: Process::Redirect::Close)
      status.success? ? output.to_s : nil
    rescue File::NotFoundError
      nil
    end
  end
end
