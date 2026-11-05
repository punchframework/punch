# The app behind spec/cli/dev_cli_spec.cr and check_cli_spec.cr: no Punch,
# so it builds in seconds, but it answers `serve` the way a Punch app does.
require "http/server"

MESSAGE = "one"

if ARGV.first? == "serve"
  server = HTTP::Server.new(&.response.print(MESSAGE))
  server.bind_tcp(ENV["PUNCH_HOST"]? || "127.0.0.1", ENV["PUNCH_PORT"].to_i)
  Process.on_terminate { server.close }
  server.listen
end
