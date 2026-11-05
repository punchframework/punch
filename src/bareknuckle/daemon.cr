require "socket"

lib LibC
  fun dup(fd : Int) : Int
end

module Bareknuckle
  # `bareknuckle serve`: `punch dev`'s warm compiler. One process per full
  # build: it builds the app as `crystal build` would, keeps the typed
  # program, and builds the rounds after it on the fast path (`Warm`) until
  # one needs a full build again. `punch dev` then starts a new process,
  # which gives the old one's memory back: typing the same program twice in
  # one process keeps most of the first one's heap.
  #
  # It answers one JSON request per line on a Unix socket:
  #
  # - `{"op":"build"}`: builds the app from the files on disk.
  #   `{"success":…,"output":…}`, the output as `crystal build --stats`
  #   prints it, or the error.
  # - `{"op":"patch","edits":{PATH:CONTENT,…}}`: the fast path.
  #   `{"success":true,"output":…,"modules":[…],"methods":[…]}`, or
  #   `{"refused":REASON,"spoiled":…}`: the round needs a full build, and,
  #   when spoiled, a new process for it.
  # - `{"op":"status"}`: the files the last build or round read, by
  #   SHA-256, and its error, for `punch typecheck`.
  # - `{"op":"verify","cache":DIR}`: compares the object cache with that
  #   of a full build with `CRYSTAL_CACHE_DIR=DIR` (`Verification`).
  #
  # It exits when its standard input closes (`punch dev` stopped).
  class Daemon
    @warm : Warm? = nil
    @spoiled = false
    @sources = {} of String => String
    @error : String? = nil
    @lock = Sync::Mutex.new

    def initialize(@main : String, @flags : Array(String), @output : String, @link_flags : String?, @socket : String,
                   @capture : String)
    end

    def run : Nil
      File.delete?(@socket)
      Dir.mkdir_p(File.dirname(@socket))
      server = UNIXServer.new(@socket)
      spawn accept(server)
      STDIN.skip_to_end rescue nil
    ensure
      server.try(&.close)
      File.delete?(@socket)
    end

    private def accept(server : UNIXServer) : Nil
      while client = server.accept?
        spawn serve(client)
      end
    end

    private def serve(client : UNIXSocket) : Nil
      client.each_line do |line|
        request = JSON.parse(line) rescue next
        reply = @lock.synchronize { handle(request) }
        client.puts(reply.to_json)
        client.flush
      end
    rescue IO::Error
    ensure
      client.close
    end

    private def handle(request : JSON::Any) : Hash(String, JSON::Any)
      case request["op"]?.try(&.as_s?)
      when "build"  then build
      when "patch"  then patch(request["edits"].as_h.transform_values(&.as_s))
      when "status" then status
      when "verify" then verify(request["cache"].as_s)
      else               {"error" => JSON::Any.new("unknown request")}
      end
    rescue ex : KeyError | TypeCastError
      {"error" => JSON::Any.new("bad request: #{ex.message}")}
    rescue ex
      # A bug in the daemon: the request fails, the daemon goes on, but
      # its program may be half changed.
      if request["op"]? == "patch"
        @warm = nil
        @spoiled = true
      end
      STDERR.puts "bareknuckle: #{request["op"]?} failed: #{ex.inspect_with_backtrace}"
      {"error" => JSON::Any.new("#{ex.class}: #{ex.message}"), "refused" => JSON::Any.new("#{ex.class}: #{ex.message}"), "spoiled" => JSON::Any.new(true)}
    end

    # Compares the object cache with a full build's in *cache*, the
    # directory `CRYSTAL_CACHE_DIR` named for it.
    private def verify(cache : String) : Hash(String, JSON::Any)
      mine = @warm.try(&.directory) || return {"error" => JSON::Any.new("no warm program to verify")}
      theirs = File.join(cache, File.basename(mine))
      {"mismatches" => JSON::Any.new(Verification.compare(mine, theirs).map { |text| JSON::Any.new(text) })}
    end

    private def build : Hash(String, JSON::Any)
      return {"success" => JSON::Any.new(false), "output" => JSON::Any.new("built already")} if @warm || @spoiled

      output = String.build do |io|
        captured(io) { @warm = Warm.build(@main, @flags, @output, @link_flags) }
        @warm.try(&.compiler.warnings.report(io))
      rescue ex : Crystal::CodeError
        ex.color = false
        ex.error_trace = false
        io << ex
        @error = ex.to_s
      rescue ex : Crystal::Error
        io << "Error: " << ex.message
        @error = ex.message
      end
      @sources = @warm.try(&.sources) || Sources.read.dup
      # Indexed now, while the app starts, so the next round need not.
      spawn { @lock.synchronize { @warm.try(&.index) } }
      {"success" => JSON::Any.new(!@warm.nil?), "output" => JSON::Any.new(output), "rss_mb" => JSON::Any.new(Warm.rss_mb.to_i64)}
    end

    private def patch(edits : Hash(String, String)) : Hash(String, JSON::Any)
      warm = @warm
      return refused("no warm program", spoiled: @spoiled) unless warm

      patched = warm.patch(edits)
      @sources = warm.sources
      # The next round's index, and the round's garbage collected, while
      # the app restarts.
      spawn do
        @lock.synchronize do
          Warm.release
          @warm.try(&.index)
        end
      end
      {
        "success" => JSON::Any.new(true),
        "output"  => JSON::Any.new(patched.stats),
        "modules" => JSON::Any.new(patched.modules.map { |name| JSON::Any.new(name) }),
        "methods" => JSON::Any.new(patched.methods.map { |name| JSON::Any.new(name) }),
        "rss_mb"  => JSON::Any.new(Warm.rss_mb.to_i64),
      }
    rescue ex : Warm::Refused
      if ex.spoiled?
        @warm = nil
        @spoiled = true
      end
      refused(ex.message || "refused", ex.spoiled?)
    rescue ex : Crystal::Error
      # Linking failed: the program is typed, the binary is not.
      @warm = nil
      @spoiled = true
      refused("Error: #{ex.message}", spoiled: true)
    end

    private def refused(reason : String, spoiled : Bool) : Hash(String, JSON::Any)
      {"refused" => JSON::Any.new(reason), "spoiled" => JSON::Any.new(spoiled)}
    end

    private def status : Hash(String, JSON::Any)
      {
        "success" => JSON::Any.new(@error.nil? && !@sources.empty?),
        "error"   => JSON::Any.new(@error),
        "files"   => JSON::Any.new(@sources.to_h { |path, content| {path, JSON::Any.new(::Digest::SHA256.hexdigest(content))} }),
      }
    end

    # Runs the block with the standard output going to *io*: the compiler
    # prints its stage times there.
    private def captured(io : IO, &) : Nil
      STDOUT.flush
      original = IO::FileDescriptor.new(LibC.dup(STDOUT.fd))
      File.open(@capture, "w") { |file| STDOUT.reopen(file) }
      begin
        yield
      ensure
        STDOUT.flush
        STDOUT.reopen(original)
        original.close
        io << File.read(@capture)
        File.delete?(@capture)
      end
    end
  end
end
