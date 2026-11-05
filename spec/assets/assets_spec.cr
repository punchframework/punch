require "../spec_helper"
require "../../src/punch/cli"

# The spec binary's assets: every spec file is one app.
Punch.assets "fixture"

module AssetsSpec
  FIXTURE = "#{__DIR__}/fixture"

  struct Layout
    include Punch::Component

    def initialize(@turbo : Bool = true, @script : Bool = true, @morph : Bool = false)
    end

    def view(v : Punch::View) : Nil
      script = Punch.asset("application.js") if @script
      v.document("Assets", stylesheets: {Punch.asset("app.css"), Punch.asset("base.css")}, script: script, turbo: @turbo, morph: @morph) do
        v.p do
          v.img src: Punch.asset("images/logo.svg").href, alt: "Punch", class: "logo"
        end
      end
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Database.memory, [] of Punch::Routing::Route), openapi: nil)
  end

  def self.gunzip(body : String) : String
    Compress::Gzip::Reader.open(IO::Memory.new(body), &.gets_to_end)
  end
end

describe Punch::Asset do
  it "is typed by extension and checked at compile time" do
    Punch.asset("app.css").should be_a(Punch::Asset::Stylesheet)
    Punch.asset("application.js").should be_a(Punch::Asset::Script)
    Punch.asset("images/dot.png").should be_a(Punch::Asset::Static)
    Punch.asset("controllers/hello.js").module_name.should eq("controllers/hello")
  end

  it "has a URL with a fingerprint of its content" do
    body = File.read("#{AssetsSpec::FIXTURE}/images/dot.png")
    Punch.asset("images/dot.png").url.should eq("/assets/images/dot-#{Digest::SHA256.hexdigest(body)[0, 16]}.png")
    Punch.asset("@acme/widgets.js").url.should match(%r{\A/assets/@acme/widgets-[0-9a-f]{16}\.js\z})
    href = Punch.asset("images/logo.svg").href
    href.url.should eq(Punch.asset("images/logo.svg").url)
    href.asset.should eq("images/logo.svg")
    href.external?.should be_false
  end

  it "embeds every file except dotfiles, bytes unchanged" do
    table = Punch::Assets.table
    table.entries.keys.sort!.should eq(["@acme/widgets.js", "@hotwired/turbo.js", "app.css", "application.js", "base.css",
                                        "controllers/hello.js", "images/dot.png", "images/logo.svg", "punch/morph.js", "punch/uploads.js"])
    table.fetch("images/dot.png").body.to_slice.should eq(File.read("#{AssetsSpec::FIXTURE}/images/dot.png").to_slice)
    table.fetch("images/dot.png").content_type.should eq("image/png")
    table.fetch("app.css").content_type.should eq("text/css; charset=utf-8")
  end

  it "embeds the vendored Turbo unchanged" do
    turbo = Punch::Assets.table.fetch("@hotwired/turbo.js")
    Digest::SHA256.hexdigest(turbo.body).should eq(Punch::Assets::Turbo::SHA256)
    turbo.body.should start_with("/*!\nTurbo #{Punch::Assets::Turbo::VERSION}\n")
    Punch::Assets.turbo.url.should eq(turbo.url)
  end

  it "points references in stylesheets at fingerprinted URLs" do
    css = Punch::Assets.table.fetch("app.css").body
    css.should contain(%(@import "#{Punch.asset("base.css").url}";))
    css.should contain(%(url("#{Punch.asset("images/dot.png").url}") no-repeat))
    css.should contain(%(url("#{Punch.asset("images/logo.svg").url}#mark")))
    css.should contain("url(data:image/png;base64,iVBORw0KGgo=)")
    css.should contain("url(https://example.org/x.png)")
    css.should contain("url('../outside.png')")
    css.should contain("url(images/gone.png)")
    Punch::Assets.table.unresolved.should eq([{"app.css", "../outside.png"}, {"app.css", "images/gone.png"}])
    # The stylesheet's fingerprint is of what is served.
    Punch.asset("app.css").url.should contain(Digest::SHA256.hexdigest(css)[0, 16])
  end

  it "maps every module in an import map" do
    map = JSON.parse(Punch::Assets.table.import_map)["imports"].as_h
    map.keys.should eq(["@acme/widgets", "@hotwired/turbo", "application", "controllers/hello", "punch/morph", "punch/uploads"])
    map["controllers/hello"].should eq(Punch.asset("controllers/hello.js").url)
    map["@hotwired/turbo"].should eq(Punch::Assets.turbo.url)
  end
end

describe "Serving assets" do
  it "answers with the content, its type, and caching for a year" do
    response = AssetsSpec.client.get(Punch.asset("images/dot.png").url)
    response.status.should eq(HTTP::Status::OK)
    response.body.to_slice.should eq(File.read("#{AssetsSpec::FIXTURE}/images/dot.png").to_slice)
    response.headers["Content-Type"].should eq("image/png")
    response.headers["Cache-Control"].should eq("public, max-age=31536000, immutable")
    response.headers["Vary"]?.should be_nil
    response.headers["Content-Encoding"]?.should be_nil
  end

  it "sends text compressed when the client accepts gzip" do
    url = Punch::Assets.turbo.url
    plain = AssetsSpec.client.get(url)
    plain.headers["Content-Encoding"]?.should be_nil
    plain.headers["Vary"].should eq("Accept-Encoding")
    plain.headers["Content-Type"].should eq("text/javascript; charset=utf-8")
    gzip = AssetsSpec.client.get(url, headers: HTTP::Headers{"Accept-Encoding" => "br, gzip"})
    gzip.headers["Content-Encoding"].should eq("gzip")
    gzip.body.bytesize.should be < plain.body.bytesize // 3
    AssetsSpec.gunzip(gzip.body).should eq(plain.body)
    refused = AssetsSpec.client.get(url, headers: HTTP::Headers{"Accept-Encoding" => "gzip;q=0, br"})
    refused.headers["Content-Encoding"]?.should be_nil
  end

  it "reads Accept-Encoding" do
    Punch::Assets.gzip?(nil).should be_false
    Punch::Assets.gzip?("gzip").should be_true
    Punch::Assets.gzip?("deflate, GZIP;q=0.5").should be_true
    Punch::Assets.gzip?("*").should be_true
    Punch::Assets.gzip?("gzip;q=0").should be_false
    Punch::Assets.gzip?("gzip; q=0.0").should be_false
    Punch::Assets.gzip?("br, x-gzip").should be_false
  end

  it "answers HEAD without a body" do
    response = AssetsSpec.client.head(Punch.asset("app.css").url)
    response.status.should eq(HTTP::Status::OK)
    response.headers["Content-Type"].should eq("text/css; charset=utf-8")
  end

  it "answers 404 for an unknown or outdated fingerprint, and for the plain name" do
    client = AssetsSpec.client
    client.get(Punch.asset("app.css").url.sub(/-[0-9a-f]{16}\./, "-0000000000000000.")).status.should eq(HTTP::Status::NOT_FOUND)
    client.get("/assets/app.css").status.should eq(HTTP::Status::NOT_FOUND)
    client.get("/assets/").status.should eq(HTTP::Status::NOT_FOUND)
    response = client.get("/assets/app.css")
    response.headers["Cache-Control"].should eq("no-store")
  end

  it "traces the request as an asset" do
    response = AssetsSpec.client.get(Punch.asset("app.css").url)
    root = response.trace.root
    root.name.should eq("GET /assets/*")
    root.attributes["punch.surface"].should eq("asset")
    root.attributes["punch.asset"].should eq("app.css")
  end

  it "allows the import map and Turbo's progress bar in the Content-Security-Policy, nothing else inline" do
    csp = AssetsSpec.client.get(Punch.asset("app.css").url).headers["Content-Security-Policy"]
    map = Punch::Assets.table.import_map
    csp.should contain("script-src 'self' 'sha256-#{Base64.strict_encode(Digest::SHA256.digest(map))}';")
    csp.should contain("style-src 'self' 'sha256-WAyOw4V+FqDc35lQPyRADLBWbuNK8ahvYEaQIYF1+Ps=';")
    csp.should start_with("default-src 'self'; ")
    csp.should contain("frame-ancestors 'none'")
    csp.should_not contain("unsafe")
  end

  it "keeps an app's own Content-Security-Policy, or none" do
    handler = ->(_context : Punch::HTTP::Context) { Punch::HTTP::Response.text(:ok, "") }
    own = Punch::HTTP::Config.new(security_headers: Punch::HTTP::SecurityHeaders.new({"Content-Security-Policy" => "default-src 'none'"}))
    Punch::Spec::Client.new(handler, openapi: nil, config: own).get("/").headers["Content-Security-Policy"].should eq("default-src 'none'")
    none = Punch::HTTP::Config.new(security_headers: Punch::HTTP::SecurityHeaders.new({"Content-Security-Policy" => nil}))
    Punch::Spec::Client.new(handler, openapi: nil, config: none).get("/").headers["Content-Security-Policy"]?.should be_nil
    Punch::Spec::Client.new(handler, openapi: nil).get("/").headers["Content-Security-Policy"].should eq(Punch::HTTP::SecurityHeaders.content_security_policy)
  end

  it "keeps operations out of the asset prefix" do
    handler = Punch::Routing::EndpointProc.new { |_, _, _| Punch::HTTP::Response.text(:ok, "") }
    route = Punch::Routing::Route.new("GET", "/assets/list", ["assets", "list"], "Assets::ListPage", "assets_list", :page, handler)
    expect_raises(ArgumentError, "Assets::ListPage is routed below /assets/") do
      Punch::Routing::Router.new(Punch::Database.memory, [route])
    end
  end
end

describe "A document's head" do
  it "loads stylesheets, the import map, Turbo, and the app's module" do
    html = Punch::Spec.render(AssetsSpec::Layout.new)
    head = html[0, html.index!("</head>")]
    head.should contain(%(<link rel="stylesheet" href="#{Punch.asset("app.css").url}" data-turbo-track="reload">\n) +
                        %(<link rel="stylesheet" href="#{Punch.asset("base.css").url}" data-turbo-track="reload">\n))
    head.should contain(%(<script type="importmap">#{Punch::Assets.table.import_map}</script>\n))
    head.should contain(%(<script type="module" src="#{Punch::Assets.turbo.url}" data-turbo-track="reload"></script>\n) +
                        %(<script type="module" src="#{Punch.asset("application.js").url}" data-turbo-track="reload"></script>\n))
    head.index!("importmap").should be < head.index!(%(type="module"))
    html.should have_element("body img.logo[alt=Punch][src='#{Punch.asset("images/logo.svg").url}']")
  end

  it "leaves out scripts and the import map without Turbo or a module" do
    html = Punch::Spec.render(AssetsSpec::Layout.new(turbo: false, script: false))
    html.should_not contain("<script")
    html.should contain(%(rel="stylesheet"))
    html = Punch::Spec.render(AssetsSpec::Layout.new(turbo: false))
    html.should_not contain(%(src="#{Punch::Assets.turbo.url}"))
    html.should contain(%(<script type="importmap">))
    html.should contain(%(src="#{Punch.asset("application.js").url}"))
  end

  it "asks Turbo to morph page refreshes, keeping the scroll position and a typed value" do
    Punch::Spec.render(AssetsSpec::Layout.new).should_not contain("turbo-refresh")
    html = Punch::Spec.render(AssetsSpec::Layout.new(morph: true))
    head = html[0, html.index!("</head>")]
    head.should contain(%(<meta name="turbo-refresh-method" content="morph">\n<meta name="turbo-refresh-scroll" content="preserve">\n))
    # and keep what the viewer is typing through the refresh.
    head.should contain(%(src="#{Punch::Assets.morph.url}"))
    Punch::Assets.table.by_url[Punch::Assets.morph.url].body.should contain("turbo:before-morph-attribute")
    Punch::Spec.render(AssetsSpec::Layout.new).should_not contain(%(src="#{Punch::Assets.morph.url}"))
    # Without Turbo there is nothing to morph.
    Punch::Spec.render(AssetsSpec::Layout.new(turbo: false, morph: true)).should_not contain("turbo-refresh")
  end
end

describe Punch::CLI::Commands::Assets do
  it "lists the assets, the import map, and unresolved references" do
    stdout = IO::Memory.new
    Punch::CLI.run(["assets", "--json"], stdout: stdout, stderr: IO::Memory.new, commands: Punch::CLI::APP_COMMANDS).should eq(0)
    json = JSON.parse(stdout.to_s)
    names = json["assets"].as_a.map(&.["name"].as_s)
    names.should contain("@hotwired/turbo.js")
    png = json["assets"].as_a.find!(&.["name"].==("images/dot.png"))
    png["url"].should eq(Punch.asset("images/dot.png").url)
    png["gzip_bytes"].raw.should be_nil
    json["import_map"]["imports"]["application"].should eq(Punch.asset("application.js").url)
    json["unresolved"][0]["reference"].should eq("../outside.png")
    text = IO::Memory.new
    Punch::CLI.run(["assets"], stdout: text, stderr: IO::Memory.new, commands: Punch::CLI::APP_COMMANDS).should eq(0)
    text.to_s.should contain("Unresolved in app.css: images/gone.png")
  end
end

describe Punch::Assets::Directory do
  it "reads the files on the first look, and again only after one changed" do
    directory = File.tempname("punch-assets")
    Dir.mkdir_p(directory)
    File.write(File.join(directory, "app.css"), "a {}")
    begin
      files = Punch::Assets::Directory.new(directory, ["app.css", "gone.js"])
      sources = {} of String => String
      start = Time.instant
      files.read(sources, start).should be_true
      sources.should eq({"app.css" => "a {}"})

      files.read(sources, start + 1.second).should be_false
      File.write(File.join(directory, "app.css"), "b {}")
      files.read(sources, start + 1.second + 100.milliseconds).should be_false # looked at too recently
      files.read(sources, start + 2.seconds).should be_true
      sources["app.css"].should eq("b {}")

      File.delete(File.join(directory, "app.css"))
      files.read(sources, start + 3.seconds).should be_true
      sources["app.css"].should eq("b {}")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe Punch::Dev do
  it "streams a reload when the version changes, and ends when the server drains" do
    io = IO::Memory.new
    version = Atomic(Int32).new(1)
    ending = Atomic(Bool).new(false)
    done = Channel(Nil).new
    spawn do
      Punch::Dev.stream(io, -> { ending.get }, -> { version.get }, tick: 5.milliseconds)
      done.send(nil)
    end
    sleep 20.milliseconds
    io.to_s.should eq("retry: 250\n\n")
    version.set(2)
    Punch::Spec.eventually(2.seconds) { io.to_s.should eq("retry: 250\n\nevent: reload\ndata: assets\n\n") }
    ending.set(true)
    done.receive
  end

  it "has a reload script that only opens the stream" do
    Punch::Dev::SCRIPT_SOURCE.should contain(%(new EventSource("/punch/dev/reload")))
  end
end
