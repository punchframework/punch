require "file_utils"

# Copies of the fixture apps under spec/, in a temporary directory on local
# disk, for the specs that run Punch's tools on an app.
module AppFixture
  ROOT = File.expand_path("#{__DIR__}/../..")

  # The shards an app that requires `punch` needs: Punch's dependencies
  # and theirs (shard.lock).
  PUNCH_SHARDS = %w[db sqlite3 email]

  # Runs the block inside a copy of *fixture* (relative to the repository)
  # whose `lib/` links `punch` and *shards* to this repository's. Examples
  # run one at a time, so changing the working directory is safe here.
  def self.copy(fixture : String, shards : Enumerable(String) = PUNCH_SHARDS, & : String ->) : Nil
    directory = File.tempname("punch-app")
    FileUtils.cp_r(File.join(ROOT, fixture), directory)
    Dir.mkdir("#{directory}/lib")
    File.symlink(ROOT, "#{directory}/lib/punch")
    shards.each { |shard| File.symlink("#{ROOT}/lib/#{shard}", "#{directory}/lib/#{shard}") }
    begin
      Dir.cd(directory) { yield directory }
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  # A port nothing listens on right now.
  def self.free_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.port.tap { server.close }
  end

  # An IO that fibers on several threads may write to while the example
  # reads it.
  class Log < IO
    @buffer = IO::Memory.new
    @lock = Mutex.new

    def write(slice : Bytes) : Nil
      @lock.synchronize { @buffer.write(slice) }
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("write-only")
    end

    def to_s : String
      @lock.synchronize { @buffer.to_s }
    end

    # What was written, also in an interpolation (a failure's message).
    def to_s(io : IO) : Nil
      io << to_s
    end
  end
end
