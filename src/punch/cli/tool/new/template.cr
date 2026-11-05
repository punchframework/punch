require "ecr"

module Punch::CLI::New
  # The app template, `template/` in Punch's root, compiled into the tool:
  # every file is ECR and sees the `App` as `app`. A path segment `__name__`
  # becomes the app's name, and the `.ecr` suffix is dropped. Which files an
  # app gets follows from its parts (`wanted?`). The reference app's shared
  # files are rendered from it too (`scripts/sync-reference.sh`).
  module Template
    ROOT = "#{__DIR__}/../../../../../template"

    # Every template file, by its path in the tree.
    PATHS = {{ `cd #{__DIR__}/../../../../../template && find . -type f -name '*.ecr' | sed 's|^\\./||' | LC_ALL=C sort`.lines.map(&.strip).reject(&.empty?) }}

    # One file of the app: where it goes, and what it holds.
    record Output, path : String, content : String

    # The files of *app*, rendered, in path order.
    def self.render(app : App) : Array(Output)
      PATHS.compact_map do |source|
        path = target(source, app)
        next unless wanted?(path, app)
        Output.new(path, render(source, app))
      end
    end

    # Where *source* goes in the app.
    def self.target(source : String, app : App) : String
      source.rchop(".ecr").gsub("__name__", app.name)
    end

    # The directories of an optional part, under `app/accounts/` and
    # `spec/accounts/`.
    # Each with what it is, for `punch generate accounts`.
    PARTS = {"magic_links"   => "sign-in by a link in an email",
             "organizations" => "organizations, members, roles held on them, and the current organization",
             "second_factor" => "a second factor (TOTP and recovery codes)",
             "tokens"        => "API tokens for programs and agents"}

    # Whether *app* gets the file at *path*.
    def self.wanted?(path : String, app : App) : Bool
      if part = part_of(path)
        return app.part?(part)
      end
      case path
      when "config/deploy.yml"                                 then app.kamal?
      when %r{\Adeploy/}                                       then app.systemd?
      when "Dockerfile", "Dockerfile.dockerignore"             then app.deploy?
      when %r{\A\.github/}                                     then app.ci?
      when %r{\Aconfig/locales/(?:[a-z_]+/)?([a-z]+)\.yml\z}   then app.languages.includes?($~[1])
      when "spec/journeys/magic_link_spec.cr"                  then app.magic_links?
      when %r{\Adb/migrations/\d+_create_organizations\.sql\z} then app.organizations?
      else                                                          true
      end
    end

    # The optional part whose directory holds *path*, if any.
    def self.part_of(path : String) : String?
      name = path.match(%r{\A(?:app|spec)/accounts/([a-z_]+)(?:/|\.cr\z|_spec\.cr\z)}).try(&.[1]) || return
      name if PARTS.has_key?(name)
    end

    # *source* rendered for *app*.
    def self.render(source : String, app : App) : String
      String.build do |io|
        {% begin %}
          {% paths = `cd #{__DIR__}/../../../../../template && find . -type f -name '*.ecr' | sed 's|^\\./||' | LC_ALL=C sort`.lines.map(&.strip).reject(&.empty?) %}
          case source
          {% for path in paths %}
            when {{ path }}
              ECR.embed {{ "#{__DIR__}/../../../../../template/#{path.id}" }}, io
          {% end %}
          else
            raise "no template #{source}"
          end
        {% end %}
      end
    end
  end
end
