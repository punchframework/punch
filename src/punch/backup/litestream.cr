require "json"
require "socket"
require "http/client"

module Punch::Backup
  # The Litestream sidecar's files in the storage directory, its generated
  # configuration, and its control socket.
  struct Litestream
    # The longest Unix socket path Linux and macOS accept.
    MAX_SOCKET_PATH = 103

    getter config : Config
    # Absolute.
    getter storage : String
    # The files replicated.
    getter names : Array(String)

    def initialize(@config : Config, storage : String, names : Enumerable(String))
      @storage = File.expand_path(storage)
      @names = config.replicated(names)
    end

    def configuration_path : String
      File.join(storage, "litestream.yml")
    end

    def socket_path : String
      File.join(storage, "litestream.sock")
    end

    def lock_path : String
      File.join(storage, "litestream.lock")
    end

    def database_path(name : String) : String
      File.join(storage, "#{name}.db")
    end

    # Why Litestream cannot run here, or `nil`: the binary is missing, or
    # the socket path is too long.
    def problem : String?
      if socket_path.bytesize > MAX_SOCKET_PATH
        return "the storage directory's path is too long for Litestream's control socket (#{socket_path.bytesize} bytes, at most #{MAX_SOCKET_PATH}): #{socket_path}"
      end

      unless executable
        "Litestream not found: #{config.litestream} (install it, or set PUNCH_LITESTREAM to its path)"
      end
    end

    # The binary's path, or `nil` when there is none.
    def executable : String?
      path = config.litestream
      if path.includes?('/')
        File.info?(path).try { |info| info.file? && info.permissions.owner_execute? } ? path : nil
      else
        Process.find_executable(path)
      end
    end

    # Litestream's configuration: each replicated file to its own path
    # under the backup URL, the control socket in the storage directory,
    # logs as JSON lines on stderr. Litestream's defaults otherwise (a sync
    # every second, a snapshot a day, its own checkpoints). Values are
    # written as JSON strings, which YAML reads as quoted scalars, and
    # `replicate` runs with `-no-expand-env`, so no `$` is expanded.
    def yaml : String
      String.build do |io|
        io << "# Written by Punch from PUNCH_BACKUP_URL at every start (lib/punch/docs/backup.md). Do not edit.\n"
        io << "socket:\n  enabled: true\n  path: " << socket_path.to_json << '\n'
        io << "logging:\n  level: info\n  type: json\n  stderr: true\n"
        io << "dbs:\n"
        names.each do |name|
          io << "  - path: " << database_path(name).to_json << '\n'
          io << "    replica:\n      url: " << config.replica_url(name).to_json << '\n'
        end
      end
    end

    # Writes `litestream.yml`, readable by its owner only.
    def write_configuration : Nil
      File.write(configuration_path, yaml, perm: File::Permissions.new(0o600))
      File.chmod(configuration_path, File::Permissions.new(0o600))
    end

    # What of this process's environment Litestream gets: its own and the
    # bucket's settings, never the master key or the app's other
    # credentials (`PUNCH_MASTER_KEY`, `PAYMENTS__…`).
    def self.environment(env = ENV) : Hash(String, String)
      env.to_h.select do |name, _|
        name.starts_with?("AWS_") || name.starts_with?("LITESTREAM_") ||
          name.in?("PATH", "HOME", "TZ", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR")
      end
    end

    # The command that replicates.
    def command : {String, Array(String)}
      {executable || config.litestream, ["replicate", "-config", configuration_path, "-no-expand-env"]}
    end

    # What the running Litestream says about one database (`GET /list`).
    record Replica, path : String, status : String, last_sync_at : Time?

    # The databases the running Litestream replicates, from its control
    # socket; `nil` when no Litestream answers there.
    def replicas(timeout : Time::Span = 2.seconds) : Array(Replica)?
      body = get("/list", timeout) || return
      parsed = JSON.parse(body)
      parsed["databases"].as_a.map do |entry|
        synced = entry["last_sync_at"]?.try(&.as_s?).try { |text| Time::Format::RFC_3339.parse(text) }
        Replica.new(entry["path"].as_s, entry["status"].as_s, synced)
      end
    rescue JSON::ParseException | TypeCastError | KeyError | Time::Format::Error
      nil
    end

    # Litestream's own version, process ID, and uptime (`GET /info`).
    record Info, version : String, pid : Int64, uptime : Time::Span

    def info(timeout : Time::Span = 2.seconds) : Info?
      body = get("/info", timeout) || return
      parsed = JSON.parse(body)
      Info.new(parsed["version"].as_s, parsed["pid"].as_i64, parsed["uptime_seconds"].as_i64.seconds)
    rescue JSON::ParseException | TypeCastError | KeyError
      nil
    end

    private def get(path : String, timeout : Time::Span) : String?
      return unless File.exists?(socket_path)

      socket = UNIXSocket.new(socket_path)
      socket.read_timeout = timeout
      socket.write_timeout = timeout
      client = ::HTTP::Client.new(socket)
      begin
        response = client.get(path, headers: ::HTTP::Headers{"Host" => "litestream"})
        response.success? ? response.body : nil
      ensure
        client.close
      end
    rescue IO::Error | Socket::Error
      nil
    end
  end
end
