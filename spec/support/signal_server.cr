# Started by spec/http/signal_spec.cr: serves until SIGTERM, then drains.
# Wide events go to stdout, the default.
require "../../src/punch"

server = Punch::HTTP::Server.new(Punch::HTTP::Config.new) do |context|
  sleep 500.milliseconds if context.request.path == "/slow"
  Punch::HTTP::Response.text(:ok, "done")
end
server.on_shutdown("report") { STDOUT.puts "drained"; STDOUT.flush }
STDOUT.puts server.bind(0).port
STDOUT.flush
server.run
