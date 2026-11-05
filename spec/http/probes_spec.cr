require "../spec_helper"
require "http/client"

private alias Probes = Punch::HTTP::Probes
private alias Config = Punch::HTTP::Config

private SCANNER = "203.0.113.7"

# A server whose handler answers 200 "app", tracing into *events*.
private def probe_server(settings = Probes::Settings.new, *, proxies = Punch::HTTP::TrustedProxies.none,
                         events = Punch::Trace::MemoryEvents.new) : Punch::HTTP::Server
  config = Config.new(probes: settings, trusted_proxies: proxies)
  tracer = Punch::Trace::Tracer.new(events: [events] of Punch::Trace::EventSink)
  Punch::HTTP::Server.new(config, tracer) { |_context| Punch::HTTP::Response.text(:ok, "app") }
end

private def ask(server : Punch::HTTP::Server, path : String, peer = SCANNER, headers = HTTP::Headers.new) : Punch::HTTP::Response
  server.process(HTTP::Request.new("GET", path, headers), peer)
end

describe Punch::HTTP::Probes do
  describe Punch::HTTP::Probes::Patterns do
    it "matches what scanners ask for, by extension, prefix, and dot segment, in any case" do
      patterns = Probes::Patterns.default
      %w[/index.php /wp-login.php /xmlrpc.php /admin/config.PHP /.env /.env.backup /prod.env /.git/config
        /app/.aws/credentials /backup.zip /db.sql /wp-admin /WP-Admin/setup-config.php /wp-content/plugins/x
        /cgi-bin/luci /phpmyadmin/ /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php /actuator/env
        /%2eenv /a/b.aspx].each do |path|
        patterns.match?(path).should be_true, "#{path} is a probe"
      end
    end

    it "leaves what browsers and the app ask for" do
      patterns = Probes::Patterns.default
      %w[/ /favicon.ico /robots.txt /apple-touch-icon.png /apple-touch-icon-precomposed.png /sitemap.xml
        /.well-known/security.txt /.well-known/acme-challenge/abc /.well-known/x.php /.well-known
        /assets/app-0123456789abcdef.css /invoices/42.md /invoices/42 /wpage /wp-admins /php
        /llms.txt /openapi.json /up].each do |path|
        patterns.match?(path).should be_false, "#{path} is no probe"
      end
    end

    it "takes entries out and in, and refuses typos" do
      patterns = Probes::Patterns.default.without(extensions: [".log"], prefixes: ["/actuator"]).with(prefixes: ["/Old-Admin"])
      patterns.match?("/server.log").should be_false
      patterns.match?("/actuator/env").should be_false
      patterns.match?("/old-admin/x").should be_true
      Probes::Patterns.default.without(dot_segments: true).match?("/.env").should be_true # by its extension
      Probes::Patterns.default.without(dot_segments: true).match?("/.git/config").should be_false
      Probes::Patterns.none.match?("/index.php").should be_false
      expect_raises(ArgumentError, /not in the list/) { Probes::Patterns.default.without(extensions: [".exe"]) }
      expect_raises(ArgumentError, /not in the list/) { Probes::Patterns.default.without(prefixes: ["/wp-login"]) }
      expect_raises(ArgumentError, /extension/) { Probes::Patterns.default.with(extensions: ["php"]) }
      expect_raises(ArgumentError, /prefix/) { Probes::Patterns.default.with(prefixes: ["/admin/"]) }
      expect_raises(ArgumentError, /well-known/) { Probes::Patterns.default.with(prefixes: ["/.well-known/x"]) }
    end

    it "names routes and assets the app could not serve" do
      Probes.conflicts(["/invoices/:invoice_id", "/wp-admin/:page", "/files/:name/download", "/.hidden", "/assets/a-0123.css", "/old.php"])
        .should eq(["/.hidden", "/old.php", "/wp-admin/:page"])
    end
  end

  it "keys addresses as bans keep them" do
    Probes.address_key("203.0.113.7").should eq("203.0.113.7")
    Probes.address_key("::ffff:203.0.113.7").should eq("203.0.113.7")
    Probes.address_key("2001:DB8:0:1::5").should eq("2001:db8:0:1::/64")
    Probes.address_key("2001:db8:0:1::/64").should eq("2001:db8:0:1::/64")
    Probes.address_key("example.org").should be_nil
  end

  it "answers a probe with an empty 404 that closes the connection, untraced" do
    events = Punch::Trace::MemoryEvents.new
    server = probe_server(events: events)
    response = ask(server, "/wp-login.php", "127.0.0.1")
    response.status.should eq(HTTP::Status::NOT_FOUND)
    response.body.should eq("")
    response.headers["Connection"].should eq("close")
    response.headers["X-Content-Type-Options"].should eq("nosniff")
    response.headers.has_key?("X-Request-ID").should be_false
    ask(server, "/invoices", "127.0.0.1").body.should eq("app")
    server.tracer.close
    events.events.map(&.["url.path"]).should eq(["/invoices"])
    server.guard.probes.get.should eq(1)
  end

  it "closes a probe's connection on a real socket, and keeps others open" do
    server = probe_server
    port = server.bind(0).port
    done = Channel(Nil).new
    spawn do
      server.run(trap_signals: false)
      done.send(nil)
    end
    begin
      socket = TCPSocket.new("127.0.0.1", port)
      socket.read_timeout = 2.seconds
      socket << "GET /index.php HTTP/1.1\r\nHost: x\r\n\r\n"
      socket.flush
      output = IO::Memory.new
      IO.copy(socket, output) # ends when the server closes
      output.to_s.should start_with("HTTP/1.1 404 Not Found\r\n")
      output.to_s.should contain("Content-Length: 0\r\n")
      output.to_s.should contain("Connection: close\r\n")
      socket.close
      HTTP::Client.get("http://127.0.0.1:#{port}/invoices").body.should eq("app")
    ensure
      server.shutdown
      done.receive
    end
  end

  it "bans after two probes within the window, for an hour, then a day, then a week" do
    clock = Punch::Spec.clock(Time.utc(2026, 11, 1, 12))
    server = probe_server
    ask(server, "/.env").status.should eq(HTTP::Status::NOT_FOUND)
    ask(server, "/invoices").body.should eq("app")
    ask(server, "/wp-login.php").status.should eq(HTTP::Status::NOT_FOUND)
    banned = ask(server, "/invoices")
    banned.status.should eq(HTTP::Status::FORBIDDEN)
    banned.body.should eq("")
    # A health checker on the same address still gets its answer.
    ask(server, "/up").status.should eq(HTTP::Status::OK)
    ask(server, "/invoices", "198.51.100.1").body.should eq("app")
    ban = server.guard.list.first
    {ban.address, ban.strikes, ban.ends_at, ban.paths}.should eq({SCANNER, 1, clock.now + 1.hour, ["/.env", "/wp-login.php"]})

    clock.advance(1.hour + 1.second)
    ask(server, "/invoices").body.should eq("app")
    2.times { ask(server, "/.git/config") }
    server.guard.list.first.strikes.should eq(2)
    clock.advance(23.hours)
    ask(server, "/invoices").status.should eq(HTTP::Status::FORBIDDEN)
    clock.advance(1.hour + 1.second)
    2.times { ask(server, "/.git/config") }
    server.guard.list.first.ends_at.should eq(clock.now + 7.days)
    server.guard.refused.get.should eq(2)
    server.guard.bans_made.get.should eq(3)
  end

  it "counts probes within the window only, and forgets the count a week after a ban ended" do
    clock = Punch::Spec.clock(Time.utc(2026, 11, 1, 12))
    server = probe_server
    ask(server, "/.env")
    clock.advance(11.minutes)
    ask(server, "/.env")
    ask(server, "/invoices").body.should eq("app")
    ask(server, "/.env")
    ask(server, "/invoices").status.should eq(HTTP::Status::FORBIDDEN)
    clock.advance(1.hour + 7.days + 1.second)
    2.times { ask(server, "/.env") }
    server.guard.list.first.strikes.should eq(1)
  end

  it "bans IPv6 clients by their /64" do
    server = probe_server
    ask(server, "/.env", "2001:db8::1")
    ask(server, "/.env", "2001:db8::2")
    ask(server, "/invoices", "2001:db8::ffff").status.should eq(HTTP::Status::FORBIDDEN)
    ask(server, "/invoices", "2001:db8:0:1::1").body.should eq("app")
  end

  it "never bans loopback, trusted proxies, allowed addresses, or private ones that came straight in" do
    allow = Punch::HTTP::TrustedProxies.parse(["198.51.100.0/24"], "allowed address")
    server = probe_server(Probes::Settings.new(allow: allow), proxies: Punch::HTTP::TrustedProxies.parse(["10.0.0.2"]))
    {"127.0.0.1", "::1", "198.51.100.9", "192.168.1.5", "172.17.0.1", "fd00::1"}.each do |peer|
      2.times { ask(server, "/.env", peer).status.should eq(HTTP::Status::NOT_FOUND) }
      ask(server, "/invoices", peer).body.should eq("app")
    end
    # A forged header from a public address does not shield it.
    forged = HTTP::Headers{"X-Forwarded-For" => "127.0.0.1"}
    2.times { ask(server, "/.env", SCANNER, forged) }
    ask(server, "/invoices", SCANNER).status.should eq(HTTP::Status::FORBIDDEN)
    # Through the trusted proxy: the forwarded client is banned, also a
    # private one, and never the proxy.
    via = HTTP::Headers{"X-Forwarded-For" => "192.168.7.7"}
    2.times { ask(server, "/.env", "10.0.0.2", via) }
    ask(server, "/invoices", "10.0.0.2", via).status.should eq(HTTP::Status::FORBIDDEN)
    ask(server, "/invoices", "10.0.0.2").body.should eq("app")
    server.guard.list.map(&.address).sort!.should eq(["192.168.7.7", SCANNER])
  end

  it "bans nobody with ban_after 0, and lets everything through when off" do
    counting = probe_server(Probes::Settings.new(ban_after: 0))
    3.times { ask(counting, "/.env").status.should eq(HTTP::Status::NOT_FOUND) }
    ask(counting, "/invoices").body.should eq("app")
    off = probe_server(Probes::Settings.new(enabled: false))
    ask(off, "/.env").body.should eq("app")
  end

  it "keeps bans in cache.db: another process reads them, a lift reaches both" do
    Punch::Spec.database(file: true) do |database|
      Punch::Caches::Durable.new(database)
      first = probe_server
      first.guard.start(database)
      2.times { ask(first, "/.env") }
      first.guard.stop
      Probes.list(database).map(&.address).should eq([SCANNER])

      second = probe_server
      second.guard.start(database)
      ask(second, "/invoices").status.should eq(HTTP::Status::FORBIDDEN)
      second.guard.lift(SCANNER).should be_true
      ask(second, "/invoices").body.should eq("app")
      Probes.list(database).should be_empty
      second.guard.lift(SCANNER).should be_false
      second.guard.stop
    end
  end

  it "reports its counters as metrics" do
    registry = Punch::Metrics::Registry.new
    server = probe_server
    server.guard.observe(registry)
    2.times { ask(server, "/.env") }
    ask(server, "/invoices")
    metrics = Punch::Spec.metrics(registry)
    metrics.value("punch.http.probes").should eq(2)
    metrics.value("punch.http.refused").should eq(1)
    metrics.value("punch.http.bans").should eq(1)
    metrics.value("punch.http.banned").should eq(1)
  end

  it "reads its settings from the environment" do
    defaults = Punch::AppConfig.from({} of String => String).as(Punch::AppConfig).probe_settings
    {defaults.enabled?, defaults.ban_after, defaults.window, defaults.bans}.should eq({true, 2, 10.minutes, [1.hour, 24.hours, 7.days]})
    settings = Punch::AppConfig.from({"PUNCH_PROBE_BAN_AFTER" => "3", "PUNCH_PROBE_WINDOW_MINUTES" => "60",
                                      "PUNCH_PROBE_BANS" => "30m, 2d", "PUNCH_PROBE_ALLOW" => "198.51.100.0/24"}).as(Punch::AppConfig).http.probes
    {settings.ban_after, settings.window, settings.bans, settings.duration(5)}.should eq({3, 1.hour, [30.minutes, 2.days], 2.days})
    settings.allow.includes?("198.51.100.9").should be_true
    Punch::AppConfig.from({"PUNCH_PROBES" => "off"}).as(Punch::AppConfig).http.probes.enabled?.should be_false
    problems = Punch::AppConfig.from({"PUNCH_PROBE_BANS" => "1h,forever", "PUNCH_PROBE_ALLOW" => "0.0.0.0/0"}).as(Array(String))
    problems.should eq(["PUNCH_PROBE_BANS must be one to ten durations from 1m to 365d, such as 1h,24h,7d, got \"1h,forever\"",
                        "PUNCH_PROBE_ALLOW: allowed address \"0.0.0.0/0\" covers every address, or nearly: name a network, no wider than /8"])
  end
end
