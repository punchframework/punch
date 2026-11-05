require "./released"
require "./upgrade"

module Punch::CLI::Commands
  # Installs the `punch` tool of a Punch release into the cache
  # (`CLI::Released`), by default the version and repository in the app's
  # `shard.lock`. The handshake then runs it in every app on that version.
  class ToolInstall < Command
    command "tool:install", "Install the punch tool of a Punch release, checked against its SHA256SUMS; by default the app's version: punch tool:install [VERSION] [--repository OWNER/NAME]"

    struct Result
      include Report

      def initialize(@version : String, @repository : String, @path : String, @present : Bool)
      end

      def to_text(io : IO) : Nil
        if @present
          io.puts "punch #{@version} from #{@repository} is already installed: #{@path}"
        else
          io.puts "Installed punch #{@version} from #{@repository}: #{@path}"
        end
        io.puts "In an app on Punch #{@version}, any punch runs it."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "version", @version
          json.field "repository", @repository
          json.field "path", @path
          json.field "installed", !@present
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      repository = AuthCommand.option(args, "--repository")
      return repository if repository.is_a?(Failure)
      if unknown = args.find(&.starts_with?("-"))
        return Failure.usage("unknown_option", "'punch tool:install' takes VERSION and --repository OWNER/NAME, not #{unknown}.")
      end
      return Failure.usage("unexpected_argument", "Usage: punch tool:install [VERSION] [--repository OWNER/NAME]") if args.size > 1

      version = args.first? || app_version || return Failure.usage("missing_argument",
        "Name the version (punch tool:install 0.2.0), or run it in an app whose shard.lock has Punch.")
      repository ||= CLI::Released.repository(".") || Punch::REPOSITORY || return Failure.new("no_repository",
        "This app depends on Punch by path, so there is no release to install from. Build the tool from the app's root with:\n  #{CLI::Handshake::BUILD}")

      case installed = CLI::Released.install(repository, version)
      in Failure then installed
      in Tuple   then Result.new(version, repository, installed[0], installed[1])
      end
    end

    private def app_version : String?
      File.exists?("shard.lock") ? CLI::Upgrade.locked_version(File.read("shard.lock")) : nil
    end
  end
end
