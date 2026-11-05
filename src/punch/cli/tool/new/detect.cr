require "yaml"

module Punch::CLI::New
  # What `punch new` was asked for, read back from an app's files: the flags
  # are not recorded, so the code is the record. `punch generate` renders
  # the template for the app it finds here, and `punch upgrade:diff` will
  # too.
  #
  # - names: `name:` in `shard.yml`, the module from `Punch.credentials`
  #   in `app/setup.cr`;
  # - optional parts: their directories under `app/accounts/`;
  # - the deploy recipe: `config/deploy.yml` (Kamal) or `deploy/`
  #   (systemd); CI: `.github/workflows/check.yml`;
  # - languages: `config/locales/<lang>.yml`; credential environments:
  #   `config/credentials/<env>.yml.enc`;
  # - Punch: the `punch:` dependency in `shard.yml`; Crystal:
  #   `.tool-versions`.
  module Detect
    # The app in *root*, or why it is not one `punch new` wrote.
    def self.app(root : String = ".") : App | String
      shard = File.join(root, "shard.yml")
      return "#{shard} is missing: run this in an app's directory" unless File.exists?(shard)
      yaml = YAML.parse(File.read(shard))
      name = yaml["name"]?.try(&.as_s?) || return "#{shard} names no app"
      # The name goes into file paths (`__name__`): only one punch new takes.
      if problem = App.name_problem(name)
        return "#{shard}: #{problem}"
      end
      module_name = module_name(root) || return "app/setup.cr has no `Punch.credentials <Module>::Credentials`: is this an app from punch new?"
      return "app/accounts/ is missing: is this an app from punch new?" unless Dir.exists?(File.join(root, "app/accounts"))
      parts = Template::PARTS.keys.to_h { |part| {part, Dir.exists?(File.join(root, "app/accounts", part))} }
      App.new(name, module_name,
        magic_links: parts["magic_links"], organizations: parts["organizations"],
        second_factor: parts["second_factor"], tokens: parts["tokens"],
        deploy: deploy(root), ci: File.exists?(File.join(root, ".github/workflows/check.yml")) ? "github" : "none",
        languages: languages(root), environments: environments(root),
        dependency: dependency(yaml), crystal: crystal(root))
    rescue ex : YAML::ParseException
      "shard.yml does not parse: #{ex.message}"
    end

    private def self.module_name(root : String) : String?
      setup = File.join(root, "app/setup.cr")
      return unless File.exists?(setup)
      File.read(setup).match(/^Punch\.credentials\s+(?:::)?([A-Z][A-Za-z0-9]*)::Credentials/m).try(&.[1])
    end

    private def self.deploy(root : String) : String
      if File.exists?(File.join(root, "config/deploy.yml"))
        "kamal"
      elsif Dir.exists?(File.join(root, "deploy"))
        "systemd"
      else
        "none"
      end
    end

    # English first, then the others in the order of `App::LANGUAGES`.
    private def self.languages(root : String) : Array(String)
      found = App::LANGUAGES.select { |code| File.exists?(File.join(root, "config/locales/#{code}.yml")) }
      (["en"] + found).uniq
    end

    private def self.environments(root : String) : Array(String)
      found = Dir.glob(File.join(root, "config/credentials/*.yml.enc")).map { |path| File.basename(path, ".yml.enc") }.sort!
      found.empty? ? App::ENVIRONMENTS.dup : found
    end

    private def self.dependency(yaml : YAML::Any) : Dependency
      punch = yaml["dependencies"]?.try(&.["punch"]?)
      version = punch.try(&.["version"]?).try(&.as_s?).try(&.lchop("~> ")) || Punch::VERSION
      if path = punch.try(&.["path"]?).try(&.as_s?)
        Dependency.new(path, nil, Punch::VERSION)
      elsif repository = punch.try(&.["github"]?).try(&.as_s?)
        Dependency.new(nil, repository, version)
      else
        Dependency.new(nil, Punch::REPOSITORY, version)
      end
    end

    private def self.crystal(root : String) : String
      versions = File.join(root, ".tool-versions")
      return CRYSTAL unless File.exists?(versions)
      File.read(versions).lines.find(&.starts_with?("crystal ")).try(&.split[1]?) || CRYSTAL
    end
  end
end
