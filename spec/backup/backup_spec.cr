require "../spec_helper"
require "http/server"

module BackupSpec
  KEYS = {"AWS_ACCESS_KEY_ID" => "AKIDSPEC", "AWS_SECRET_ACCESS_KEY" => "secret-spec"}

  # Every wide event, so a spec can see what was reported.
  class Events < Punch::Trace::EventSink
    getter events = [] of Punch::Trace::Span
    @lock = Mutex.new

    def emit(event : Punch::Trace::Span) : Nil
      @lock.synchronize { @events << event }
    end

    def reported : Array(Exception)
      @lock.synchronize { @events.flat_map(&.exceptions.map(&.exception)) }
    end
  end

  def self.tracer : {Punch::Trace::Tracer, Events}
    events = Events.new
    {Punch::Trace::Tracer.new(events: [events] of Punch::Trace::EventSink), events}
  end

  # A stand-in for an S3 endpoint: answers with the queued status, headers,
  # and body, then 500; keeps every request.
  class S3
    record Answer, status : Int32, body : String, headers : ::HTTP::Headers = ::HTTP::Headers.new
    record Received, resource : String, headers : ::HTTP::Headers

    getter received = [] of Received
    @answers = Deque(Answer).new
    @lock = Mutex.new

    def initialize
      @server = ::HTTP::Server.new do |context|
        answer = @lock.synchronize do
          @received << Received.new(context.request.resource, context.request.headers)
          @answers.shift? || Answer.new(500, "")
        end
        context.response.status_code = answer.status
        answer.headers.each { |name, values| context.response.headers[name] = values }
        context.response.print answer.body
      end
      @address = @server.bind_tcp("127.0.0.1", 0)
      # A spec may close it before this fiber runs.
      spawn { @server.listen rescue nil }
    end

    def answer(status : Int32, body : String = "", headers : ::HTTP::Headers = ::HTTP::Headers.new) : Nil
      @lock.synchronize { @answers << Answer.new(status, body, headers) }
    end

    def config(env = {} of String => String) : Punch::Backup::Config
      Punch::Backup::Config.from(env.merge({"PUNCH_BACKUP_URL" => "s3://invoices/app?endpoint=http://127.0.0.1:#{@address.port}&region=eu-central-1"}), [] of String)
    end

    def close : Nil
      @server.close
    end
  end

  # A stand-in for Litestream's control socket.
  class Socket
    @lists = Deque(String).new
    @lock = Mutex.new

    def initialize(path : String)
      @server = ::HTTP::Server.new do |context|
        case context.request.path
        when "/list"
          context.response.print(@lock.synchronize { @lists.size > 1 ? @lists.shift : @lists.first? } || %({"databases":[]}))
        when "/info"
          context.response.print %({"version":"0.5.17","pid":4242,"uptime_seconds":12,"started_at":"2026-10-14T05:00:00Z","database_count":1})
        else
          context.response.status_code = 404
        end
      end
      @server.bind_unix(path)
      # A spec may close it before this fiber runs.
      spawn { @server.listen rescue nil }
    end

    def list(json : String) : Nil
      @lock.synchronize { @lists << json }
    end

    def close : Nil
      @server.close
    end
  end

  def self.storage(& : String ->) : Nil
    directory = File.tempname("punch-backup")
    Dir.mkdir(directory)
    begin
      yield directory
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  # A Litestream that only records that it ran: its process ID goes into
  # `pids` next to the configuration, and SIGTERM ends it.
  def self.fake_litestream(directory : String) : String
    path = File.join(directory, "fake-litestream")
    File.write(path, <<-SH)
      #!/bin/sh
      echo $$ >> "$(dirname "$3")/pids"
      trap 'exit 0' TERM
      while true; do sleep 0.02; done
      SH
    File.chmod(path, 0o755)
    path
  end

  def self.pids(directory : String) : Array(Int64)
    path = File.join(directory, "pids")
    File.exists?(path) ? File.read_lines(path).map(&.to_i64) : [] of Int64
  end

  def self.alive?(pid : Int64) : Bool
    Process.exists?(pid) && !File.read("/proc/#{pid}/stat").split(' ')[2].in?("Z", "X")
  rescue File::Error
    false
  end
end

describe Punch::Backup::Config do
  it "reads the replica, exemptions, encryption, and binary from the environment" do
    problems = [] of String
    config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "s3://backups/invoices?endpoint=https://s3.example.net&region=auto",
                                         "PUNCH_BACKUP_EXEMPT" => "ops, queue", "PUNCH_BACKUP_ENCRYPTION" => "provider",
                                         "PUNCH_LITESTREAM" => "/opt/litestream"}, problems)
    problems.should be_empty
    config.exempt.should eq(%w[ops queue])
    config.encryption.provider?.should be_true
    config.litestream.should eq("/opt/litestream")
    config.s3?.should be_true
    config.replica_url("primary").should eq("s3://backups/invoices/primary?endpoint=https://s3.example.net&region=auto")
    config.replicated(%w[primary cache queue ops]).should eq(%w[primary])
    config.missing(%w[primary queue ops]).should be_empty
  end

  it "replicates every file except the cache, and names those lacking a replica" do
    none = Punch::Backup::Config.new
    none.replicated(%w[primary cache queue ops]).should be_empty
    none.missing(%w[primary cache queue ops]).should eq(%w[primary queue ops])
    file = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///var/backups/app/"}, [] of String)
    file.replicated(%w[primary cache queue ops]).should eq(%w[primary queue ops])
    file.replica_url("queue").should eq("file:///var/backups/app/queue")
    file.s3?.should be_false
  end

  it "reports every problem" do
    problems = [] of String
    Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "s3://AKID:secret@backups/app", "PUNCH_BACKUP_EXEMPT" => "cache",
                                "PUNCH_BACKUP_ENCRYPTION" => "maybe"}, problems)
    problems.size.should eq(3)
    problems[0].should contain("must not hold keys")
    problems[0].should_not contain("secret")
    problems[1].should contain(%(PUNCH_BACKUP_EXEMPT: "cache"))
    problems[2].should contain("check or provider")
    {"gs://bucket/app", "file://relative/path", "file:relative", "backups"}.each do |url|
      Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => url}, problems.clear)
      problems.size.should eq(1)
    end
  end

  it "is part of the process settings" do
    settings = Punch::AppConfig.from({"PUNCH_BACKUP_URL" => "file:///srv/backups"}).as(Punch::AppConfig)
    settings.backup.replica_url("primary").should eq("file:///srv/backups/primary")
    Punch::AppConfig.from({"PUNCH_BACKUP_URL" => "ftp://x"}).as(Array(String)).first.should start_with("PUNCH_BACKUP_URL")
  end
end

describe Punch::Backup::Encryption do
  it "signs as AWS's published Signature Version 4 example" do
    credentials = Punch::S3::SigV4::Credentials.new("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", nil)
    headers = Punch::S3::SigV4.sign("GET", "iam.amazonaws.com", "/", {"Action" => "ListUsers", "Version" => "2010-05-08"},
      ::HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded; charset=utf-8"}, credentials, "us-east-1", "iam",
      Time.utc(2015, 8, 30, 12, 36, 0))
    headers["Authorization"].should eq("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, " \
                                       "SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    credentials.inspect.should_not contain("wJalr")
  end

  it "asks the bucket for its default encryption" do
    s3 = BackupSpec::S3.new
    s3.answer(200, "<ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>")
    Punch::Backup::Encryption.check(s3.config, BackupSpec::KEYS).should eq(Punch::Backup::Encryption::Encrypted.new("aws:kms"))
    request = s3.received.first
    request.resource.should eq("/invoices?encryption=")
    request.headers["Authorization"].should match(%r{\AAWS4-HMAC-SHA256 Credential=AKIDSPEC/\d{8}/eu-central-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=[0-9a-f]{64}\z})
    request.headers["X-Amz-Content-Sha256"].should eq(Digest::SHA256.hexdigest(""))
  ensure
    s3.try(&.close)
  end

  it "tells a bucket without encryption from one that does not say" do
    s3 = BackupSpec::S3.new
    s3.answer(404, "<Error><Code>ServerSideEncryptionConfigurationNotFoundError</Code></Error>")
    s3.answer(403, "<Error><Code>AccessDenied</Code></Error>")
    s3.answer(501, "<Error><Code>NotImplemented</Code></Error>")
    Punch::Backup::Encryption.check(s3.config, BackupSpec::KEYS).should eq(Punch::Backup::Encryption::Unencrypted.new)
    Punch::Backup::Encryption.check(s3.config, BackupSpec::KEYS).should eq(Punch::Backup::Encryption::Unknown.new("GetBucketEncryption answered 403 AccessDenied"))
    Punch::Backup::Encryption.check(s3.config, BackupSpec::KEYS).should eq(Punch::Backup::Encryption::Unknown.new("GetBucketEncryption answered 501 NotImplemented"))
  ensure
    s3.try(&.close)
  end

  it "asks again in the region the bucket names" do
    s3 = BackupSpec::S3.new
    s3.answer(301, "<Error><Code>PermanentRedirect</Code></Error>", ::HTTP::Headers{"x-amz-bucket-region" => "eu-west-3"})
    s3.answer(200, "<ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>")
    Punch::Backup::Encryption.check(s3.config, BackupSpec::KEYS).should eq(Punch::Backup::Encryption::Encrypted.new("AES256"))
    s3.received.last.headers["Authorization"].should contain("/eu-west-3/s3/aws4_request")
  ensure
    s3.try(&.close)
  end

  it "does not ask without keys, for a file replica, or when the provider encrypts" do
    s3 = BackupSpec::S3.new
    Punch::Backup::Encryption.check(s3.config, {} of String => String).should be_a(Punch::Backup::Encryption::Unknown)
    Punch::Backup::Encryption.check(s3.config({"PUNCH_BACKUP_ENCRYPTION" => "provider"}), BackupSpec::KEYS).should be_a(Punch::Backup::Encryption::NotChecked)
    file = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups"}, [] of String)
    Punch::Backup::Encryption.check(file, BackupSpec::KEYS).should eq(Punch::Backup::Encryption::NotChecked.new("file replica"))
    s3.received.should be_empty
  ensure
    s3.try(&.close)
  end

  it "says no answer came when the endpoint is unreachable" do
    config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "s3://invoices/app?endpoint=http://127.0.0.1:1"}, [] of String)
    Punch::Backup::Encryption.check(config, BackupSpec::KEYS, timeout: 1.second).should be_a(Punch::Backup::Encryption::Unknown)
  end
end

describe Punch::Backup::Litestream do
  it "passes Litestream its own settings and the bucket's, never the master key or other credentials" do
    env = {"PUNCH_MASTER_KEY" => "k", "PAYMENTS__WEBHOOK_SECRET" => "s", "AWS_SECRET_ACCESS_KEY" => "a", "LITESTREAM_ACCESS_KEY_ID" => "l", "PATH" => "/bin"}
    Punch::Backup::Litestream.environment(env).should eq({"AWS_SECRET_ACCESS_KEY" => "a", "LITESTREAM_ACCESS_KEY_ID" => "l", "PATH" => "/bin"})
  end

  it "writes Litestream's configuration: each file to its own path, the socket in storage" do
    config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "s3://backups/app?endpoint=http://minio:9000", "PUNCH_BACKUP_EXEMPT" => "ops"}, [] of String)
    litestream = Punch::Backup::Litestream.new(config, "/srv/app $HOME", %w[primary cache queue ops])
    litestream.names.should eq(%w[primary queue])
    litestream.yaml.should eq(<<-YAML)
      # Written by Punch from PUNCH_BACKUP_URL at every start (lib/punch/docs/backup.md). Do not edit.
      socket:
        enabled: true
        path: "/srv/app $HOME/litestream.sock"
      logging:
        level: info
        type: json
        stderr: true
      dbs:
        - path: "/srv/app $HOME/primary.db"
          replica:
            url: "s3://backups/app/primary?endpoint=http://minio:9000"
        - path: "/srv/app $HOME/queue.db"
          replica:
            url: "s3://backups/app/queue?endpoint=http://minio:9000"

      YAML
    litestream.command[1].should eq(["replicate", "-config", "/srv/app $HOME/litestream.yml", "-no-expand-env"])
  end

  it "says why it cannot run" do
    BackupSpec.storage do |directory|
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups", "PUNCH_LITESTREAM" => File.join(directory, "none")}, [] of String)
      Punch::Backup::Litestream.new(config, directory, %w[primary]).problem.to_s.should contain("Litestream not found")
      fake = BackupSpec.fake_litestream(directory)
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups", "PUNCH_LITESTREAM" => fake}, [] of String)
      Punch::Backup::Litestream.new(config, directory, %w[primary]).problem.should be_nil
      Punch::Backup::Litestream.new(config, File.join(directory, "x" * 100), %w[primary]).problem.to_s.should contain("too long")
    end
  end

  it "reads the replicas and Litestream's version from its control socket" do
    BackupSpec.storage do |directory|
      litestream = Punch::Backup::Litestream.new(Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups"}, [] of String), directory, %w[primary])
      litestream.replicas.should be_nil
      socket = BackupSpec::Socket.new(litestream.socket_path)
      socket.list(%({"databases":[{"path":"#{litestream.database_path("primary")}","status":"replicating","last_sync_at":"2026-10-14T05:07:09.123456Z"}]}))
      litestream.replicas.should eq([Punch::Backup::Litestream::Replica.new(litestream.database_path("primary"), "replicating", Time.utc(2026, 10, 14, 5, 7, 9, nanosecond: 123_456_000))])
      litestream.info.should eq(Punch::Backup::Litestream::Info.new("0.5.17", 4242, 12.seconds))
      socket.close
    end
  end
end

describe Punch::Backup::Monitor do
  it "measures lag as the time since the last upload, when something changed after it" do
    now = Time.utc(2026, 10, 14, 12, 0, 0)
    since = now - 1.hour
    Punch::Backup::Monitor.lag(now - 10.seconds, now - 5.seconds, since, now).should eq(Time::Span.zero)
    Punch::Backup::Monitor.lag(now - 5.seconds, now - 10.seconds, since, now).should eq(10.seconds)
    Punch::Backup::Monitor.lag(nil, nil, since, now).should eq(Time::Span.zero)
    # Never synced: since the change, or since this process started.
    Punch::Backup::Monitor.lag(now - 2.hours, nil, since, now).should eq(1.hour)
    Punch::Backup::Monitor.lag(now - 3.seconds, nil, since, now).should eq(3.seconds)
  end

  it "fails the health check for a missing replica outside development and test" do
    litestream = Punch::Backup::Litestream.new(Punch::Backup::Config.new, "/srv/app", %w[primary cache queue ops])
    names = %w[primary cache queue ops]
    Punch::Backup::Monitor.new(litestream, names, "production").health.should eq(
      "backup: no replica for primary.db, queue.db, ops.db: set PUNCH_BACKUP_URL, or exempt them with PUNCH_BACKUP_EXEMPT")
    Punch::Backup::Monitor.new(litestream, names, "development").health.should be_nil
    Punch::Backup::Monitor.new(litestream, names, "test").health.should be_nil
    exempt = Punch::Backup::Config.from({"PUNCH_BACKUP_EXEMPT" => "primary,queue,ops"}, [] of String)
    Punch::Backup::Monitor.new(Punch::Backup::Litestream.new(exempt, "/srv/app", names), names, "production").health.should be_nil
  end

  it "fails the health check for a bucket not known to encrypt, and reports it once" do
    s3 = BackupSpec::S3.new
    tracer, events = BackupSpec.tracer
    litestream = Punch::Backup::Litestream.new(s3.config, "/srv/app", %w[primary])
    monitor = Punch::Backup::Monitor.new(litestream, %w[primary], "production", tracer, env: BackupSpec::KEYS)
    monitor.health.should be_nil
    s3.answer(404, "<Error><Code>ServerSideEncryptionConfigurationNotFoundError</Code></Error>")
    s3.answer(404, "<Error><Code>ServerSideEncryptionConfigurationNotFoundError</Code></Error>")
    s3.answer(200, "<SSEAlgorithm>AES256</SSEAlgorithm>")
    monitor.check_encryption
    monitor.health.to_s.should contain("the bucket has no default encryption")
    monitor.check_encryption
    events.reported.map(&.class).should eq([Punch::Backup::NotEncrypted])
    monitor.check_encryption
    monitor.health.should be_nil
  ensure
    s3.try(&.close)
  end

  it "measures each file's lag from the socket and the WAL, and reports a lagging one once" do
    BackupSpec.storage do |directory|
      tracer, events = BackupSpec.tracer
      litestream = Punch::Backup::Litestream.new(Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups"}, [] of String), directory, %w[primary queue])
      now = Time.utc.at_beginning_of_second
      File.write(litestream.database_path("primary"), "")
      File.write("#{litestream.database_path("primary")}-wal", "")
      File.touch("#{litestream.database_path("primary")}-wal", now - 1.second)
      File.write(litestream.database_path("queue"), "")
      File.touch(litestream.database_path("queue"), now - 20.minutes)
      socket = BackupSpec::Socket.new(litestream.socket_path)
      entries = {"primary" => now - 10.minutes, "queue" => now - 15.minutes}.map do |name, synced|
        %({"path":"#{litestream.database_path(name)}","status":"replicating","last_sync_at":"#{synced.to_rfc3339}"})
      end
      socket.list(%({"databases":[#{entries.join(',')}]}))
      registry = Punch::Metrics::Registry.new
      monitor = Punch::Backup::Monitor.new(litestream, %w[primary queue], "production", tracer, now: now - 1.hour)
      monitor.observe(registry)
      lags = monitor.measure(now)
      lags["primary"].should eq(10.minutes)
      lags["queue"].should eq(Time::Span.zero)
      Punch::Spec.metrics(registry).value("punch.backup.lag", "db.namespace": "primary").should eq(600.0)
      monitor.measure(now + 1.second)
      events.reported.map(&.message).should eq(["primary.db has not reached its replica for 600 s"])
      # Litestream gone: the lag grows from the last upload seen.
      socket.close
      monitor.measure(now + 1.minute)["primary"].should eq(11.minutes)
    end
  end
end

describe Punch::Backup::Sidecar do
  it "runs one Litestream for every process on the storage, and the next takes over" do
    BackupSpec.storage do |directory|
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups", "PUNCH_LITESTREAM" => BackupSpec.fake_litestream(directory)}, [] of String)
      litestream = Punch::Backup::Litestream.new(config, directory, %w[primary])
      first = Punch::Backup::Sidecar.new(litestream, retry: 50.milliseconds)
      second = Punch::Backup::Sidecar.new(litestream, retry: 50.milliseconds)
      first.start
      Punch::Spec.eventually { BackupSpec.pids(directory).size.should eq(1) }
      second.start
      sleep 200.milliseconds
      BackupSpec.pids(directory).size.should eq(1)
      first.holder?.should be_true
      second.holder?.should be_false
      File.info(litestream.configuration_path).permissions.value.should eq(0o600)

      first.stop
      BackupSpec.alive?(BackupSpec.pids(directory).first).should be_false
      Punch::Spec.eventually { BackupSpec.pids(directory).size.should eq(2) }
      second.holder?.should be_true
      second.stop
      BackupSpec.pids(directory).none? { |pid| BackupSpec.alive?(pid) }.should be_true
    end
  end

  it "starts Litestream again when it exits, and reports it" do
    BackupSpec.storage do |directory|
      tracer, events = BackupSpec.tracer
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups", "PUNCH_LITESTREAM" => BackupSpec.fake_litestream(directory)}, [] of String)
      sidecar = Punch::Backup::Sidecar.new(Punch::Backup::Litestream.new(config, directory, %w[primary]), tracer)
      sidecar.start
      Punch::Spec.eventually { BackupSpec.pids(directory).size.should eq(1) }
      Process.signal(Signal::KILL, BackupSpec.pids(directory).first)
      Punch::Spec.eventually(3.seconds) { BackupSpec.pids(directory).size.should eq(2) }
      sidecar.restarts.should eq(1)
      sidecar.running?.should be_true
      events.reported.first.message.should match(/\ALitestream exited with signal KILL after .* s; starting it again in 2 s\z/)
      sidecar.stop
      sidecar.running?.should be_false
    end
  end

  it "keeps the lock while an orphaned Litestream runs" do
    BackupSpec.storage do |directory|
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups", "PUNCH_LITESTREAM" => BackupSpec.fake_litestream(directory)}, [] of String)
      litestream = Punch::Backup::Litestream.new(config, directory, %w[primary])
      # A process that started Litestream with the lock inherited, then died.
      lock = File.open(litestream.lock_path, "a")
      lock.flock_exclusive
      lock.close_on_exec = false
      orphan = Process.new(BackupSpec.fake_litestream(directory), ["replicate", "-config", litestream.configuration_path])
      lock.close
      sidecar = Punch::Backup::Sidecar.new(litestream, retry: 50.milliseconds)
      sidecar.start
      sleep 200.milliseconds
      sidecar.holder?.should be_false
      orphan.terminate
      orphan.wait
      Punch::Spec.eventually { sidecar.holder?.should be_true }
      sidecar.stop
    end
  end
end

describe "Litestream replicating Punch databases" do
  it "uploads what was written and stops after syncing the last write" do
    unless Process.find_executable("litestream")
      pending! "litestream is not installed"
    end
    BackupSpec.storage do |directory|
      storage = File.join(directory, "storage")
      Dir.mkdir(storage)
      databases = Punch::Databases.open(storage, %w[primary])
      databases.primary.write do |writer|
        writer.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT")
        100.times { |i| writer.exec("INSERT INTO notes (body) VALUES (?)", "note #{i}") }
      end
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file://#{directory}/replica"}, [] of String)
      litestream = Punch::Backup::Litestream.new(config, storage, %w[primary])
      sidecar = Punch::Backup::Sidecar.new(litestream, output: :close)
      monitor = Punch::Backup::Monitor.new(litestream, %w[primary], "production")
      sidecar.start
      Punch::Spec.eventually(10.seconds) do
        litestream.replicas.try(&.first?).try(&.last_sync_at).should_not be_nil
        monitor.measure["primary"].should eq(Time::Span.zero)
      end
      litestream.info.try(&.version).to_s.should start_with("0.5")
      databases.primary.write(&.exec("INSERT INTO notes (body) VALUES ('last')"))
      databases.close
      sidecar.stop
      restored = File.join(directory, "restored.db")
      Process.run("litestream", ["restore", "-o", restored, config.replica_url("primary")], error: :inherit).success?.should be_true
      copy = Punch::Database.open(restored)
      copy.read(&.query_one?("SELECT count(*) FROM notes", &.read(Int64))).should eq(101)
      copy.read(&.query_one?("PRAGMA integrity_check", &.read(String))).should eq("ok")
      # Litestream's tables are in the file, not in a schema dump.
      copy.read(&.query_all("SELECT name FROM sqlite_schema WHERE name LIKE '\\_litestream%' ESCAPE '\\'", &.read(String))).sort.should eq(%w[_litestream_lock _litestream_seq])
      Punch::Migrations::Schema.dump(copy).should_not contain("_litestream")
      copy.close
    end
  end
end
