module Punch::CLI::New
  # Where a new app finds Punch: a path while Punch has no repository
  # (`Punch::REPOSITORY` is `nil`), else its git repository at the version
  # the tool was built from.
  record Dependency, path : String?, repository : String?, version : String do
    # The `punch:` entry of `shard.yml`, indented under `dependencies:`.
    def to_yaml_entry : String
      if repo = repository
        "  punch:\n    github: #{repo}\n    version: \"~> #{version}\""
      else
        "  punch:\n    path: #{path}"
      end
    end
  end

  # What `punch new` was asked for: the names, the optional parts, and the
  # recipes. Every template sees it as `app`.
  struct App
    LANGUAGES = %w[en de]
    # Production is started when deploying (`punch creds:init --env
    # production`): its values are the deployment's.
    ENVIRONMENTS = %w[development test]
    DEPLOYS      = %w[kamal systemd none]
    CIS          = %w[github none]

    # The shard, the binary, and the directory: `tally`.
    getter name : String
    # The app's top-level module: `Tally`.
    getter module_name : String
    getter? magic_links : Bool
    getter? organizations : Bool
    getter? second_factor : Bool
    getter? tokens : Bool
    getter deploy : String
    getter ci : String
    getter languages : Array(String)
    getter environments : Array(String)
    getter dependency : Dependency
    # The Crystal release Punch pins (`toolchain.env`).
    getter crystal : String

    def initialize(@name, @module_name, *, @magic_links = false, @organizations = false, @second_factor = true,
                   @tokens = true, @deploy = "kamal", @ci = "github", @languages = ["en"],
                   @environments = ENVIRONMENTS.dup, @dependency = Dependency.new(nil, nil, Punch::VERSION),
                   @crystal = New::CRYSTAL)
    end

    # The module for *name*: `tally` is `Tally`, `time_sheets` and
    # `time-sheets` are `TimeSheets`.
    def self.module_for(name : String) : String
      name.split(/[-_]/).reject(&.empty?).map(&.capitalize).join
    end

    # What is wrong with *name* as a shard and binary name, or `nil`.
    def self.name_problem(name : String) : String?
      return "an app name is lowercase letters, digits, - and _, starting with a letter, got '#{name}'" unless name.matches?(/\A[a-z][a-z0-9_-]*\z/)
      "'#{name}' is too long; keep it under 50 characters" if name.size >= 50
    end

    # What is wrong with *name* as the app's module, or `nil`.
    def self.module_problem(name : String) : String?
      return "a module name is a Crystal constant such as Tally, got '#{name}'" unless name.matches?(/\A[A-Z][A-Za-z0-9]*\z/)
      "#{name} is a slice of every new app; choose another module name" if name.in?("Accounts", "Home")
    end

    # Whether the app has the optional *part* (`Template::PARTS`).
    def part?(part : String) : Bool
      case part
      when "magic_links"   then magic_links?
      when "organizations" then organizations?
      when "second_factor" then second_factor?
      when "tokens"        then tokens?
      else                      raise ArgumentError.new("not a part: #{part}")
      end
    end

    # This app with the optional *part* added (`punch generate accounts`).
    def with_part(part : String) : App
      raise ArgumentError.new("not a part: #{part}") unless Template::PARTS.has_key?(part)
      App.new(name, module_name,
        magic_links: magic_links? || part == "magic_links", organizations: organizations? || part == "organizations",
        second_factor: second_factor? || part == "second_factor", tokens: tokens? || part == "tokens",
        deploy: deploy, ci: ci, languages: languages, environments: environments, dependency: dependency, crystal: crystal)
    end

    # Whether the deploy recipes are written at all.
    def deploy? : Bool
      deploy != "none"
    end

    def kamal? : Bool
      deploy == "kamal"
    end

    def systemd? : Bool
      deploy == "systemd"
    end

    def ci? : Bool
      ci != "none"
    end

    # The SHA-256 of the Linux archive of the pinned Crystal for *arch*
    # (`x86_64` or `aarch64`), from `toolchain.env`.
    def crystal_sha256(arch : String) : String
      New::CRYSTAL_SHA256[arch]
    end

    # The prefix of the app's API tokens (`tal_…`): the name's first
    # three letters, so people and secret scanners can tell whose they are.
    def token_prefix : String
      letters = name.delete("-_0-9")
      letters[0, {letters.size, 3}.min]
    end

    # The app's name for people, and the issuer an authenticator app shows
    # for the second factor: `time-sheets` is `Time Sheets`.
    def title : String
      name.split(/[-_]/).reject(&.empty?).map(&.capitalize).join(" ")
    end

    # The title as it appears in an `otpauth://` URI.
    def title_uri : String
      URI.encode_path_segment(title)
    end
  end
end
