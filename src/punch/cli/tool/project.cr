require "yaml"

module Punch::CLI
  # The app or shard in the current directory, as its `shard.yml` declares
  # it. The standalone commands that build the app (`openapi`, `routes`,
  # `dev`, `check`) start here.
  struct Project
    getter name : String
    getter version : String
    # Name and main file of each target, in declaration order.
    getter targets : Array({String, String})
    # Whether it depends on Punch, so its binary knows `routes`.
    getter? punch_app : Bool

    def initialize(@name : String, @version : String, @targets : Array({String, String}), @punch_app : Bool = false)
    end

    # The project in the current directory, or the failure `no_app`.
    def self.load(file : String = "shard.yml") : Project | Failure
      problem = "#{file} with a name, a version, and at least one target is needed; run this from the app's root."
      return Failure.new("no_app", "No #{problem}") unless File.exists?(file)

      shard = YAML.parse(File.read(file))
      name, version = shard["name"]?.try(&.as_s?), shard["version"]?.try(&.as_s?)
      targets = shard["targets"]?.try(&.as_h?).try &.compact_map do |target, settings|
        settings["main"]?.try(&.as_s?).try { |main| {target.as_s, main} }
      end
      return Failure.new("no_app", "A #{problem}") if name.nil? || version.nil? || targets.nil? || targets.empty?

      new(name, version, targets, shard["dependencies"]?.try(&.as_h?).try(&.has_key?("punch")) || false)
    rescue ex : YAML::ParseException
      Failure.new("no_app", "#{file} does not parse: #{ex.message}")
    end

    # The app's main file: its first target's.
    def main : String
      targets.first[1]
    end

    # Where the derivation build goes.
    DERIVATION_BINARY = "tmp/punch-openapi/app"

    # When set, `derivation` builds once per app directory and process:
    # `punch check` derives OpenAPI and the payload lock from one build.
    class_property? reuse_derivation = false
    @@derived = {} of String => String

    # Builds the app with `-Dpunch_openapi`, the derivation build: OpenAPI
    # (`openapi:derive`) and the payload lock (`jobs:derive`) come from it,
    # so normal builds do not compile the derivation. Returns the binary.
    def derivation : String | Failure
      key = File.join(Dir.current, main)
      return DERIVATION_BINARY if Project.reuse_derivation? && @@derived[key]?

      build = Project.build(main, DERIVATION_BINARY, ["-Dpunch_openapi"])
      return Failure.new("build_failed", "Building #{main} with -Dpunch_openapi failed:\n#{build.output}") unless build.success

      @@derived[key] = DERIVATION_BINARY
      DERIVATION_BINARY
    end

    # A finished `crystal build`: whether it succeeded, and what the
    # compiler printed.
    record Build, success : Bool, output : String, retried : Bool = false

    # Builds *main* into *output*, retrying once when only linking failed:
    # Crystal's object cache occasionally fails a warm rebuild with an
    # undefined reference, and the next build succeeds.
    #
    # *env* is added to the compiler's environment (`CRYSTAL_CACHE_DIR`).
    def self.build(main : String, output : String, flags : Array(String) = [] of String, env : Hash(String, String)? = nil) : Build
      Dir.mkdir_p(File.dirname(output))
      first = compile(main, output, flags, env)
      return first if first.success || !link_failure?(first.output)

      second = compile(main, output, flags, env)
      Build.new(second.success, second.output, retried: true)
    end

    # Type-checks *main* without generating code (`crystal build
    # --no-codegen`): every error the compiler finds, macros included, and
    # no binary. About a third of a build's time when it passes.
    def self.typecheck(main : String, flags : Array(String) = [] of String) : Build
      log = IO::Memory.new
      status = Process.run("crystal", ["build", main, "--no-codegen", "--no-color"] + flags, output: log, error: log)
      Build.new(status.success?, log.to_s)
    end

    # Whether the compiler got as far as linking and the linker failed.
    def self.link_failure?(output : String) : Bool
      output.includes?("undefined reference to") || output.matches?(/execution of command failed with (exit status|code) \d+: (cc|clang|gcc|ld)\b/)
    end

    private def self.compile(main : String, output : String, flags : Array(String), env : Hash(String, String)?) : Build
      log = IO::Memory.new
      status = Process.run("crystal", ["build", main, "-o", output, "--no-color"] + flags, env: env, output: log, error: log)
      Build.new(status.success?, log.to_s)
    end
  end
end
