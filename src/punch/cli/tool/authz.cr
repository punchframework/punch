require "./project"

module Punch::CLI::Commands
  # `punch authz:explain` for the app in the current directory: builds the
  # derivation build (`-Dpunch_openapi`), which alone has the explainers,
  # and asks it (`Commands::AuthzExplain`, docs/authorization.md).
  class ToolAuthzExplain < Command
    command "authz:explain", "Why a user may or may not run an operation: punch authz:explain OPERATION --user ID [name=value ...]"

    def run(args : Array(String)) : Report | Failure
      project = Project.load
      return project if project.is_a?(Failure)

      binary = project.derivation
      return binary if binary.is_a?(Failure)

      output, error = IO::Memory.new, IO::Memory.new
      status = Process.run(binary, ["authz:explain"] + args + ["--json"], output: output, error: error)
      document = begin
        JSON.parse(output.to_s)
      rescue JSON::ParseException
        return Failure.new("explain_failed", "#{binary} authz:explain failed:\n#{error}#{output}")
      end
      return AuthzExplain::Result.new(document) if status.success?

      failure = document["error"]
      code, message = failure["code"].as_s, failure["message"].as_s
      status.exit_code == 2 ? Failure.usage(code, message) : Failure.new(code, message)
    end
  end
end
