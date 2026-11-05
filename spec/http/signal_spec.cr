require "../spec_helper"
require "http/client"

# Waits for *channel* or fails after *timeout*, so a regression fails the
# example instead of hanging the suite.
private def receive_within(channel : Channel(T), timeout : Time::Span) : T forall T
  select
  when value = channel.receive then value
  when timeout(timeout) then fail "timed out after #{timeout}"
  end
end

describe "SIGTERM" do
  it "drains requests in progress, writes their wide events, and exits cleanly" do
    binary = File.tempname("punch-signal-server")
    Process.run("crystal", ["build", "#{__DIR__}/../support/signal_server.cr", "-o", binary],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).success?.should be_true
    reader, writer = IO.pipe
    process = Process.new(binary, output: writer, error: Process::Redirect::Close)
    writer.close
    begin
      port = reader.gets.try(&.to_i) || fail "server did not start"
      result = Channel(String).new(1)
      spawn { result.send(HTTP::Client.new("127.0.0.1", port).get("/slow").body) }
      sleep 100.milliseconds
      process.signal(Signal::TERM)
      receive_within(result, 5.seconds).should eq("done")

      exited = Channel(Process::Status).new(1)
      spawn { exited.send(process.wait) }
      receive_within(exited, 5.seconds).success?.should be_true
      output = reader.gets_to_end
      output.should contain("drained")
      events = output.lines.compact_map { |line| JSON.parse(line) if line.starts_with?('{') }
      event = events.find { |json| json["url.path"]? == "/slow" }
      event.should_not be_nil
      event.try(&.["http.response.status_code"]).should eq(200)
    ensure
      process.terminate(graceful: false) unless process.terminated?
    end
  ensure
    File.delete?(binary) if binary
  end
end
