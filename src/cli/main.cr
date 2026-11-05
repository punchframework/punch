require "../punch"
require "../punch/cli/tool"

if failure = Punch::CLI::Handshake.enforce(ARGV)
  ARGV.includes?("--json") ? (failure.to_json(STDOUT); puts) : STDERR.puts("punch: #{failure.message}")
  exit failure.exit_code
end

exit Punch::CLI.run(ARGV, commands: Punch::CLI::TOOL_COMMANDS, fallback: Punch::CLI::Forward::FALLBACK)
