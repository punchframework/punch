require "yaml"
require "../../version"
require "./released"

module Punch::CLI
  # Version of what the tool writes into an app (generated queries, i18n
  # modules, the payload lock). Bump it when an output changes shape, so a
  # tool built from other sources than the app's `lib/punch` is caught even
  # while `Punch::VERSION` is the same.
  GENERATOR_FORMAT = 1

  # The check that the `punch` tool matches the app's `lib/punch`: the tool
  # holds the generators, so one from another Punch would write files the app
  # does not expect. A mismatch re-execs `lib/punch/bin/punch` (as a Bundler
  # binstub does) when it exists, or the release's tool `punch tool:install`
  # put in the cache, and otherwise refuses with the commands that get one.
  module Handshake
    # Where an app keeps the tool that matches its Punch.
    TOOL = "lib/punch/bin/punch"
    # Set for the re-exec'd tool, so that it does not check, and re-exec,
    # again.
    GUARD = "PUNCH_TOOL_REEXEC"
    BUILD = "crystal build lib/punch/src/cli/main.cr -o #{TOOL} --release"

    record Proceed
    record Reexec, path : String
    record Refuse, failure : Failure

    # What to do in *root* (the app's directory) for the tool *executable*
    # with *version* and *format*: nothing to check where there is no
    # `lib/punch` (the Punch repository itself, or an app without it).
    def self.decide(root : String, executable : String?, version : String = Punch::VERSION,
                    format : Int32 = GENERATOR_FORMAT, guarded : Bool = !ENV[GUARD]?.nil?,
                    tools : String = Released.cache) : Proceed | Reexec | Refuse
      return Proceed.new if guarded

      library = File.join(root, "lib", "punch")
      shard = File.join(library, "shard.yml")
      return Proceed.new unless File.file?(shard)

      theirs = library_version(shard)
      return Proceed.new unless theirs # not a Punch checkout we can read: leave it alone

      their_format = library_format(library)
      return Proceed.new if theirs == version && (their_format.nil? || their_format == format)

      repository = Released.repository(root)
      if matching = matching_tool(root, repository, theirs, executable, tools)
        return Reexec.new(matching)
      end

      ours = "This tool is Punch #{version} (generator format #{format})"
      want = "the app's lib/punch is #{theirs}#{" (format #{their_format})" if their_format}"
      Refuse.new(Failure.new("tool_mismatch", "#{ours}, #{want}. Its generators could write files the app does not expect. #{how_to_get(repository, theirs)}"))
    end

    # The tool of the app's Punch, *theirs*, other than *executable*: the
    # app's own build, else the release's tool installed in *tools*. A
    # release's tool is built from that version's sources, so its generator
    # format is theirs.
    private def self.matching_tool(root : String, repository : String?, theirs : String, executable : String?, tools : String) : String?
      tool = File.join(root, TOOL)
      return tool if File::Info.executable?(tool) && !same_file?(tool, executable)

      released = repository.try { |name| Released.installed(name, theirs, tools) }
      released unless released.nil? || same_file?(released, executable)
    end

    # The commands that get the tool of *theirs*.
    private def self.how_to_get(repository : String?, theirs : String) : String
      if repository
        "Install the matching tool from the release with:\n  punch tool:install #{theirs}\nor build it from the app's root with:\n  #{BUILD}\nThe tool then re-runs it for you."
      else
        "Build the matching tool from the app's root with:\n  #{BUILD}\nThe tool then re-runs it for you; or run #{TOOL} directly."
      end
    end

    # The version in *shard*, `lib/punch/shard.yml`.
    def self.library_version(shard : String) : String?
      YAML.parse(File.read(shard))["version"]?.try(&.as_s?)
    rescue YAML::ParseException
    end

    # The generator format the sources in *library* declare, nil when they
    # predate it.
    def self.library_format(library : String) : Int32?
      File.read(File.join(library, "src", "punch", "cli", "tool", "handshake.cr")).match(/^  GENERATOR_FORMAT = (\d+)/m).try(&.[1].to_i)
    rescue File::Error
    end

    private def self.same_file?(path : String, other : String?) : Bool
      return false unless other

      File.realpath(path) == File.realpath(other)
    rescue File::Error
      false
    end

    # Runs at the start of the standalone `punch`: re-execs the matching
    # tool, or returns the failure to report. Commands that need no app
    # (`help`, `version`) always run, and so does `tool:install`, which
    # fetches the matching tool.
    def self.enforce(argv : Array(String), root : String = Dir.current) : Failure?
      return if argv.reject("--json").first?.in?(nil, "help", "version", "--help", "-h", "--version", "tool:install")

      case decision = decide(root, Process.executable_path)
      in Proceed then nil
      in Reexec  then Process.exec(decision.path, argv, env: {GUARD => "1"})
      in Refuse  then decision.failure
      end
    end
  end
end
