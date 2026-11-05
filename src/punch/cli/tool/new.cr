require "./new/app"
require "./new/template"
require "./new/detect"

module Punch
  # Punch's GitHub repository (`owner/name`), for the `shard.yml` of new
  # apps (`punch new`): set by the release build from `PUNCH_REPOSITORY`
  # (packaging/build-tool.sh). `nil` for a tool built from a checkout: new
  # apps then depend on that checkout, by path.
  REPOSITORY = {{ env("PUNCH_REPOSITORY") }}.as(String?)
end

module Punch::CLI::New
  # The Crystal release Punch pins, for `.tool-versions` and CI.
  CRYSTAL = {{ read_file("#{__DIR__}/../../../../toolchain.env").lines.find(&.starts_with?("CRYSTAL_VERSION=")).split("=")[1].strip }}
  # The SHA-256 of its Linux archives, by architecture, for the
  # devcontainer that downloads it.
  CRYSTAL_SHA256 = {
    "x86_64"  => {{ read_file("#{__DIR__}/../../../../toolchain.env").lines.find(&.starts_with?("CRYSTAL_SHA256_LINUX_X86_64=")).split("=")[1].strip }},
    "aarch64" => {{ read_file("#{__DIR__}/../../../../toolchain.env").lines.find(&.starts_with?("CRYSTAL_SHA256_LINUX_AARCH64=")).split("=")[1].strip }},
  }

  # Punch's root, as the tool was built from it: a new app's path
  # dependency while there is no repository.
  ROOT = {{ "#{__DIR__}/../../../..".id.stringify }}

  # The development login `db/seeds.cr` signs up.
  SEED_EMAIL = "admin@example.test"
  # Where `db/seeds.cr` keeps the development user's random password.
  SEED_PASSWORD_FILE = "storage/seed-password"

  # One thing `punch new` did after writing the files: a step's name, and
  # the command and its output when it ran.
  record Step, name : String, status : Symbol, detail : String do
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "name", name
        json.field "status", status.to_s
        json.field "detail", detail
      end
    end
  end

  # Runs commands in a directory, in order, until one fails: `punch new`
  # after writing, and `punch generate`.
  module Steps
    # Each planned step is a name, a command (`punch` for this tool), and
    # what it reads from stdin. Returns the steps run and, after a
    # failure, the commands left to run, the failed one first.
    def self.run(directory : String, planned : Array({String, Array(String), String?})) : {Array(Step), Array(String)}
      punch = Process.executable_path || "punch"
      steps = [] of Step
      planned.each_with_index do |(name, command, input), index|
        command = command.map { |word| word == "punch" ? punch : word }
        output = IO::Memory.new
        stdin = input ? IO::Memory.new(input) : Process::Redirect::Close
        status = Process.run(command[0], command[1..], chdir: directory, input: stdin, output: output, error: output,
          env: {"PUNCH_ENV" => nil, "PUNCH_STORAGE" => nil})
        unless status.success?
          steps << Step.new(name, :failed, "$ #{display(command, nil, punch)}\n#{output}")
          return {steps, planned[index..].map { |(_, rest, text)| display(rest, text, punch) }}
        end
        steps << Step.new(name, :done, output.to_s)
      rescue ex : File::NotFoundError | IO::Error
        steps << Step.new(name, :failed, "$ #{command.join(' ')}\n#{ex.message}")
        return {steps, planned[index..].map { |(_, rest, text)| display(rest, text, punch) }}
      end
      {steps, [] of String}
    end

    # *command* as a person types it, with what it reads from stdin:
    # `punch` for this tool.
    def self.display(command : Array(String), input : String?, punch : String) : String
      words = command.join(' ') { |word| word == punch ? "punch" : (word.includes?(' ') ? "'#{word}'" : word) }
      input ? "echo #{input} | #{words}" : words
    end
  end
end

module Punch::CLI::Commands
  # Writes a new app: the accounts slice with the chosen parts, the
  # skeleton, `AGENTS.md`, and the recipes, from the template compiled into
  # this tool. Then makes it ready and proves it: dependencies, credentials,
  # the database, the generated files, the development seed, `punch check`,
  # and a first commit.
  class New < Command
    command "new", "Create an app: punch new NAME|. [--module NAME] [--magic-links] [--organizations] [--no-second-factor] [--no-tokens] " \
                   "[--deploy kamal|systemd|none] [--ci github|none] [--languages en,de] [--environments development,test] " \
                   "[--path DIR] [--skip-install] [--skip-git]"

    struct Result
      include Report

      def initialize(@app : CLI::New::App, @directory : String, @files : Array(String), @steps : Array(CLI::New::Step),
                     @next : Array(String))
      end

      def to_text(io : IO) : Nil
        io.puts "Created #{@app.module_name} in #{@directory} (#{@files.size} files)."
        unless @app.dependency.repository
          io.puts "Punch is a path dependency on #{@app.dependency.path}: Punch has no repository yet."
        end
        @steps.each { |step| io.puts "  #{step.status.to_s.ljust(7)} #{step.name}" }
        unless @next.empty?
          io.puts
          io.puts "Next:"
          @next.each { |line| io.puts "  #{line}" }
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "directory", @directory
          json.field "module", @app.module_name
          json.field "files", @files
          json.field "steps", @steps
          json.field "next", @next
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      parsed = parse(args)
      return parsed if parsed.is_a?(Failure)

      directory, app, install, git = parsed
      if problem = target_problem(directory)
        return Failure.new("directory_not_empty", problem)
      end

      files = CLI::New::Template.render(app)
      files.each do |file|
        path = ::File.join(directory, file.path)
        Dir.mkdir_p(::File.dirname(path))
        ::File.write(path, file.content)
        ::File.chmod(path, 0o755) if file.path.ends_with?(".sh")
      end
      steps, remaining = setup(directory, app, install, git)
      cd = directory == "." ? nil : "cd #{directory}"
      following = [cd].compact + remaining
      unless steps.any?(&.status.==(:failed))
        following << "punch dev    # then sign in as #{CLI::New::SEED_EMAIL}, the password in #{CLI::New::SEED_PASSWORD_FILE}"
      end
      result = Result.new(app, directory, files.map(&.path), steps, following)
      if failed = steps.find(&.status.==(:failed))
        details = JSON.parse(result.to_json)
        return Failure.new("setup_failed", "#{failed.name} failed in #{directory}; the files are written. " \
                                           "Fix it, then run:\n  #{following.join("\n  ")}\n\n#{failed.detail.rstrip}", details: details)
      end
      result
    end

    # The directory, the app, and whether to install and commit.
    private def parse(args : Array(String)) : {String, CLI::New::App, Bool, Bool} | Failure
      args = args.dup
      flags = %w[--magic-links --organizations --no-second-factor --no-tokens --skip-install --skip-git].to_h do |flag|
        {flag, !args.delete(flag).nil?}
      end
      options = {} of String => String
      %w[--module --deploy --ci --languages --environments --path].each do |name|
        value = AuthCommand.option(args, name)
        return value if value.is_a?(Failure)

        options[name] = value if value
      end
      if unknown = args.find(&.starts_with?("-"))
        return Failure.usage("unexpected_argument", "'punch new' does not know #{unknown}. #{self.class.summary}")
      end
      return Failure.usage("missing_argument", "Usage: #{self.class.summary.split(": ", 2).last}") unless args.size == 1

      directory = args.first
      names = names(directory, options["--module"]?)
      return names if names.is_a?(Failure)

      choices = choices(options)
      return choices if choices.is_a?(Failure)

      deploy, ci, languages, environments = choices
      app = CLI::New::App.new(names[0], names[1],
        magic_links: flags["--magic-links"], organizations: flags["--organizations"],
        second_factor: !flags["--no-second-factor"], tokens: !flags["--no-tokens"],
        deploy: deploy, ci: ci, languages: languages, environments: environments, dependency: dependency(options["--path"]?))
      {directory, app, !flags["--skip-install"], !flags["--skip-git"]}
    end

    # The app's name, from its directory, and its module.
    private def names(directory : String, module_name : String?) : {String, String} | Failure
      name = ::File.basename(::File.expand_path(directory))
      if problem = CLI::New::App.name_problem(name)
        return Failure.usage("invalid_name", "Cannot name the app after #{directory}: #{problem}.")
      end

      module_name ||= CLI::New::App.module_for(name)
      if problem = CLI::New::App.module_problem(module_name)
        return Failure.usage("invalid_module", "#{problem.capitalize}; pass --module NAME.")
      end

      {name, module_name}
    end

    # The recipe, CI, languages, and credential environments.
    private def choices(options : Hash(String, String)) : {String, String, Array(String), Array(String)} | Failure
      deploy = options["--deploy"]? || "kamal"
      return choice_failure("--deploy", deploy, CLI::New::App::DEPLOYS) unless deploy.in?(CLI::New::App::DEPLOYS)

      ci = options["--ci"]? || "github"
      return choice_failure("--ci", ci, CLI::New::App::CIS) unless ci.in?(CLI::New::App::CIS)

      languages = list(options["--languages"]?, ["en"])
      if unknown_language = languages.find { |language| !language.in?(CLI::New::App::LANGUAGES) }
        return choice_failure("--languages", unknown_language, CLI::New::App::LANGUAGES)
      end

      environments = list(options["--environments"]?, CLI::New::App::ENVIRONMENTS.dup)
      if bad = environments.find { |environment| !environment.matches?(/\A[a-z0-9_]+\z/) }
        return Failure.usage("invalid_environment", "An environment name is lowercase letters, digits, and _, got '#{bad}'.")
      end
      unless environments.includes?("development")
        return Failure.usage("invalid_environment", "--environments must include development: the seed and `punch dev` run there.")
      end

      {deploy, ci, (["en"] + languages).uniq, environments}
    end

    # Punch by *path*, by its repository, or by the checkout this tool
    # was built from while it has none.
    private def dependency(path : String?) : CLI::New::Dependency
      if path
        CLI::New::Dependency.new(::File.expand_path(path), nil, Punch::VERSION)
      elsif repository = Punch::REPOSITORY
        CLI::New::Dependency.new(nil, repository, Punch::VERSION)
      else
        CLI::New::Dependency.new(::File.expand_path(CLI::New::ROOT), nil, Punch::VERSION)
      end
    end

    private def list(value : String?, default : Array(String)) : Array(String)
      value ? value.split(',').map(&.strip).reject!(&.empty?).uniq! : default
    end

    private def choice_failure(option : String, value : String, choices : Array(String)) : Failure
      Failure.usage("invalid_choice", "#{option} takes #{choices.join(", ")}, not '#{value}'.")
    end

    # Why the app cannot be written to *directory*: it exists and is not
    # empty.
    private def target_problem(directory : String) : String?
      return unless Dir.exists?(directory)
      return if Dir.empty?(directory)

      "#{directory} exists and is not empty; punch new writes only into a new or empty directory."
    end

    # Runs the steps after writing in order, until one fails: their results,
    # and the commands left to run.
    private def setup(directory : String, app : CLI::New::App, install : Bool, git : Bool) : {Array(CLI::New::Step), Array(String)}
      punch = "punch"
      planned = [] of {String, Array(String), String?}
      # The templates' conditions leave blank lines where a part is left
      # out; the formatter settles them.
      planned << {"crystal tool format", ["crystal", "tool", "format", "app", "spec", "src", "db"], nil}
      if install
        planned << {"shards install", ["shards", "install"], nil}
      end
      app.environments.each do |environment|
        planned << {"credentials (#{environment})", [punch, "creds:init", "--env", environment], nil}
        planned << {"key ring (#{environment})", [punch, "keys:rotate", "--env", environment], nil}
        planned << {"public-ID key (#{environment})", [punch, "keys:public-id", "--env", environment], nil}
        if environment.in?("development", "test")
          planned << {"mail settings (#{environment})", [punch, "creds:set", "mail.delivery", "--env", environment], "capture"}
          planned << {"mail sender (#{environment})", [punch, "creds:set", "mail.from", "--env", environment], "#{app.name}@example.test"}
        end
      end
      if install
        [{"db:migrate", [punch, "db:migrate"]}, {"db:generate", [punch, "db:generate"]},
         {"i18n:generate", [punch, "i18n:generate"]}, {"requires:generate", [punch, "requires:generate"]},
         {"openapi", [punch, "openapi"]}, {"jobs:lock", [punch, "jobs:lock"]},
         {"db:seed", [punch, "db:seed"]}, {"punch check", [punch, "check"]}].each do |name, command|
          planned << {name, command, nil}
        end
      end
      if git
        planned << {"git init", ["git", "init", "--quiet"], nil}
        planned << {"git add", ["git", "add", "--all"], nil}
        planned << {"first commit", ["git", "commit", "--quiet", "-m", "New app from punch new #{Punch::VERSION}"], nil}
      end
      steps, remaining = CLI::New::Steps.run(directory, planned)
      return {steps, remaining} if steps.any?(&.status.==(:failed))

      skipped = [] of String
      skipped.concat(["shards install", "punch db:migrate", "punch db:seed", "punch check"]) unless install
      skipped.concat(["git init && git add --all && git commit -m 'New app'"]) unless git
      {steps, skipped}
    end
  end
end
