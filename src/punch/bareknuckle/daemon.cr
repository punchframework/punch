require "json"
require "socket"

module Punch::Bareknuckle
  # `punch dev`'s side of the bareknuckle daemon, `bareknuckle serve`,
  # opt-in (`punch dev --bareknuckle`): one process per full build, which
  # then builds the rounds after it on the fast path until one needs a full
  # build again. `punch dev` starts it, sends it requests on a Unix socket
  # (`SOCKET`) and waits for each answer; `punch typecheck` asks it what the
  # last round found (`status`).
  #
  # The binary is built from Punch's own sources (`punch bareknuckle:build`)
  # into `bin/` beside them, the app's `lib/punch/bin/bareknuckle`. It
  # only starts when it is built from the Crystal release the app builds
  # with, and from the current sources. It links its own LLVM, so it keeps
  # its own object cache: bitcode from two LLVM releases never compares
  # equal.
  class Daemon
    SOCKET = "#{RoundLog::DIRECTORY}/bareknuckle.sock"

    # Punch's sources, where the tool was built from.
    ROOT   = File.expand_path("../../..", __DIR__)
    SOURCE = "#{ROOT}/src/bareknuckle/main.cr"
    BINARY = "#{ROOT}/bin/bareknuckle"
    # What the binary is built from: its own sources and the parse-only
    # code it shares with the tool.
    INPUTS = ["#{ROOT}/src/bareknuckle", "#{ROOT}/src/punch/bareknuckle/fingerprint.cr"]

    # A build or a round: whether it succeeded, and what the compiler
    # printed (`crystal build --stats` and the error).
    record Built, success : Bool, output : String

    # A round on the fast path: the modules generated again and the
    # methods typed again.
    record Patched, output : String, modules : Array(String), methods : Array(String)

    # Why a round needed a full build; *spoiled* when the daemon cannot
    # serve another round.
    record Refused, reason : String, spoiled : Bool

    @socket : UNIXSocket

    def initialize(@process : Process, @socket : UNIXSocket)
    end

    # Why the daemon cannot run here; `nil` when it can.
    def self.unavailable : String?
      return "not built; `punch bareknuckle:build` builds it" unless File.exists?(BINARY)

      outdated
    end

    # Starts a daemon for *main* built with *flags* (`-Dpunch_dev`) into
    # *output*, or says why it does not start.
    def self.start(main : String, flags : Array(String), output : String, link_flags : String?, cache : String) : Daemon | String
      if reason = unavailable
        return reason
      end

      defines = flags.compact_map(&.lchop?("-D")).flat_map { |flag| ["-D", flag] }
      args = ["serve", "--main", main, "--output", output, "--socket", SOCKET] + defines
      link_flags.try { |value| args.concat(["--link-flags", value]) }
      File.delete?(SOCKET)
      process = Process.new(BINARY, args, env: Daemon.env(cache), input: Process::Redirect::Pipe,
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      deadline = Time.instant + 5.seconds
      until File.exists?(SOCKET)
        return "did not start" if process.terminated? || Time.instant > deadline
        sleep 20.milliseconds
      end
      new(process, UNIXSocket.new(SOCKET))
    rescue ex : IO::Error | File::Error | Socket::Error
      "did not start: #{ex.message}"
    end

    # What the daemon and its one-shot builds need from `crystal env`: where
    # the standard library and Crystal's own libraries are, and *cache*.
    def self.env(cache : String) : Hash(String, String)
      {"CRYSTAL_PATH" => crystal("CRYSTAL_PATH"), "CRYSTAL_LIBRARY_PATH" => crystal("CRYSTAL_LIBRARY_PATH"), "CRYSTAL_CACHE_DIR" => cache}
    end

    # Why the binary cannot build like `crystal build`: built from another
    # Crystal release, or from older sources; `nil` when it can.
    def self.outdated : String?
      built = File.info(BINARY).modification_time
      newer = INPUTS.any? do |input|
        Dir.exists?(input) ? Dir.glob("#{input}/**/*.cr").any? { |file| File.info(file).modification_time > built } : File.info(input).modification_time > built
      end
      return "built from older sources; `punch bareknuckle:build` rebuilds it" if newer

      output = IO::Memory.new
      Process.run(BINARY, ["version"], output: output)
      binary = JSON.parse(output.to_s)["crystal"]?.try(&.as_s?)
      app = crystal("CRYSTAL_VERSION")
      "built for Crystal #{binary}, the app builds with #{app}; `punch bareknuckle:build` rebuilds it" unless binary == app
    rescue JSON::ParseException | File::Error | IO::Error
      "does not run; `punch bareknuckle:build` rebuilds it"
    end

    # *name* from `crystal env`: what the builds use.
    def self.crystal(name : String) : String
      output = IO::Memory.new
      Process.run("crystal", ["env", name], output: output)
      output.to_s.strip
    end

    # A full build, from the files on disk; `nil` when the daemon stopped.
    def build : Built?
      reply = ask({op: "build"}) || return
      Built.new(reply["success"].as_bool, reply["output"].as_s)
    end

    # The fast path for *edits* (new contents by absolute path); `nil`
    # when the daemon stopped.
    def patch(edits : Hash(String, String)) : (Patched | Refused)?
      reply = ask({op: "patch", edits: edits}) || return
      if reason = reply["refused"]?
        Refused.new(reason.as_s, reply["spoiled"].as_bool)
      else
        Patched.new(reply["output"].as_s, reply["modules"].as_a.map(&.as_s), reply["methods"].as_a.map(&.as_s))
      end
    end

    # How the object cache compares with that of a full build with
    # `CRYSTAL_CACHE_DIR=cache` (`bareknuckle build`): what differs; `nil`
    # when the daemon stopped.
    def verify(cache : String) : Array(String)?
      reply = ask({op: "verify", cache: cache}) || return
      reply["mismatches"]?.try(&.as_a.map(&.as_s)) || [reply["error"]?.try(&.as_s?) || "no answer"]
    end

    # Stops the daemon: closing its input ends it.
    def stop : Nil
      @socket.close rescue nil
      @process.input.close rescue nil
      deadline = Time.instant + 2.seconds
      until @process.terminated? || Time.instant > deadline
        sleep 20.milliseconds
      end
      @process.terminate rescue nil unless @process.terminated?
    end

    def running? : Bool
      !@process.terminated?
    end

    private def ask(request) : JSON::Any?
      @socket.puts(request.to_json)
      @socket.flush
      line = @socket.gets || return
      JSON.parse(line)
    rescue IO::Error | JSON::ParseException
      nil
    end

    # What the daemon serving this app found in the last build or round,
    # for `punch typecheck`: the files it read (absolute path to SHA-256)
    # and its error. `nil` when no daemon answers.
    def self.status : {Hash(String, String), String?}?
      return unless File.exists?(SOCKET)

      UNIXSocket.open(SOCKET) do |socket|
        # The daemon answers once the build it runs is done.
        socket.read_timeout = 2.minutes
        socket.puts({op: "status"}.to_json)
        socket.flush
        reply = JSON.parse(socket.gets || return)
        return if reply["files"].as_h.empty?

        {reply["files"].as_h.transform_values(&.as_s), reply["error"]?.try(&.as_s?)}
      end
    rescue IO::Error | Socket::Error | JSON::ParseException | KeyError | TypeCastError
      nil
    end
  end
end
