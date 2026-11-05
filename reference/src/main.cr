require "./invoicing"
require "punch/cli"

exit Punch::CLI.run(ARGV, commands: Punch::CLI::APP_COMMANDS)
