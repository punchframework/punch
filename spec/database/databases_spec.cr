require "../spec_helper"
require "http/client"

private def with_directory(& : String ->)
  directory = File.tempname("punch-spec")
  Dir.mkdir(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe Punch::Databases do
  it "opens one file with its own writer per name" do
    with_directory do |directory|
      databases = Punch::Databases.open(directory, %w[primary queue])
      begin
        databases.names.should eq(%w[primary queue])
        databases.primary.write(&.exec("CREATE TABLE t (id INTEGER PRIMARY KEY) STRICT"))
        databases["queue"].write(&.exec("CREATE TABLE jobs (id INTEGER PRIMARY KEY) STRICT"))
        File.exists?(File.join(directory, "primary.db")).should be_true
        File.exists?(File.join(directory, "queue.db")).should be_true
        expect_raises(Punch::Database::Error, /no such table/) { databases.primary.read(&.query_all("SELECT * FROM jobs", &.read(Int64))) }
        expect_raises(KeyError, /no database cache; open: primary, queue/) { databases["cache"] }
      ensure
        databases.close
      end
      databases.primary.closed?.should be_true
      databases["queue"].closed?.should be_true
    end
  end

  it "rejects names that are not plain identifiers, and closes what it opened" do
    with_directory do |directory|
      expect_raises(ArgumentError, /invalid database name/) { Punch::Databases.open(directory, ["primary", "../x"]) }
      Dir.children(directory).should_not contain("x.db")
    end
  end

  it "reports each database in the server's health check and closes them after the drain" do
    databases = Punch::Databases.memory(%w[primary ops])
    server = Punch::HTTP::Server.new(Punch::HTTP::Config.new, Punch::Trace::Tracer.off) { |_| Punch::HTTP::Response.text(:ok, "hi") }
    databases.attach(server)
    port = server.bind(0).port
    spawn { server.run }
    client = HTTP::Client.new("127.0.0.1", port)
    client.get("/up").status_code.should eq(200)
    databases["ops"].close
    response = client.get("/up")
    response.status_code.should eq(503)
    response.body.should contain("ops: closed")
    server.shutdown
    databases.primary.closed?.should be_true
  end
end
