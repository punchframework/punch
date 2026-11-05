require "digest/sha256"
require "compress/gzip"
require "base64"
require "json"
require "./view/href"
require "./assets/turbo"
require "./dev"

module Punch
  # A file of the app's asset directory, named by its path there:
  # `Punch.asset("app.css")`, `Punch.asset("images/logo.svg")`. A name that
  # is not in the directory does not compile.
  #
  # Its URL carries a fingerprint of its content
  # (`/assets/app-3f2a9c0d1e4b5a6f.css`) and is cached by browsers for a
  # year, so a changed file gets a new URL.
  #
  # Stylesheets and scripts have their own types, so that `v.document`
  # takes only what it can load: `Asset::Stylesheet` (`.css`),
  # `Asset::Script` (`.js`, an ES module), and `Asset::Static` for the rest.
  abstract struct Asset
    getter name : String

    # :nodoc:
    def initialize(@name : String)
    end

    # The fingerprinted path, such as `/assets/app-3f2a9c0d1e4b5a6f.css`.
    def url : String
      Assets.table.fetch(@name).url
    end

    # A link to the asset, for `src:` or `href:`:
    # `v.img src: Punch.asset("logo.svg").href, alt: "Punch"`.
    def href : Href
      Href.new(url, nil, asset: @name)
    end

    def to_s(io : IO) : Nil
      io << url
    end

    struct Stylesheet < Asset
    end

    # An ES module. Bare names in its imports resolve through the import
    # map: `import "@hotwired/turbo"`, `import "controllers/hello"`.
    struct Script < Asset
      # The module's name in the import map: its path without `.js`.
      def module_name : String
        @name.rchop(".js")
      end
    end

    struct Static < Asset
    end
  end

  # Embeds every file below *dir* (relative to the file that calls this) in
  # the binary, as the app's assets. Once per app, at the top level:
  #
  # ```
  # # app/assets.cr
  # Punch.assets "assets"
  # ```
  #
  # File names use letters, digits, `_`, `-`, `.`, and `@`; files starting
  # with a dot are left out. An extension Punch cannot serve
  # (`Punch::Assets::TYPES`) does not compile.
  #
  # A `punch dev` build (`-Dpunch_dev`) checks the same at compile time but
  # reads the files from the directory while it runs, so a changed file is
  # served without a build (`Assets.directory`); a new or removed file
  # still needs one.
  macro assets(dir)
    {% if @top_level.has_constant?("PunchAssetNames") %}
      {% raise "Punch.assets: an app has one asset directory, and it is already declared" %}
    {% end %}
    {% base = @caller.first.filename.split("/")[0..-2].join("/") + "/" + dir %}
    {% listing = system("cd '#{base.id}' 2>/dev/null && find . -type f ! -path '*/.*' | LC_ALL=C sort || echo PUNCH_NO_DIRECTORY").lines %}
    {% if listing.includes?("PUNCH_NO_DIRECTORY") %}
      {% raise "Punch.assets: no directory #{base}" %}
    {% end %}
    {% names = listing.map { |line| line[2..] } %}
    {% for name in names %}
      {% unless name =~ /\A[A-Za-z0-9_@][A-Za-z0-9_.@-]*(\/[A-Za-z0-9_@][A-Za-z0-9_.@-]*)*\z/ %}
        {% raise "Punch.assets: #{name} is not a usable asset name; use letters, digits, _, -, ., and @" %}
      {% end %}
      {% extension = name.split("/").last.split(".") %}
      {% unless extension.size > 1 && ::Punch::Assets::TYPES.keys.includes?(extension.last.downcase) %}
        {% raise "Punch.assets: #{name} has no extension Punch serves (#{::Punch::Assets::TYPES.keys.join(", ").id})" %}
      {% end %}
      {% if name.starts_with?("@hotwired/turbo") %}
        {% raise "Punch.assets: #{name}: Punch provides Turbo itself (Punch::Assets::Turbo)" %}
      {% end %}
    {% end %}

    # The names of the app's assets, read by `Punch.asset` at compile time.
    PunchAssetNames = {{ names.empty? ? "[] of String".id : names }}

    {% if flag?(:punch_dev) %}
      ::Punch::Assets.directory({{ base }}, PunchAssetNames)
    {% else %}
      {% for name in names %}
        ::Punch::Assets.add({{ name }}, {{ read_file("#{base.id}/#{name.id}") }})
      {% end %}
    {% end %}
  end

  # The app's asset *name* (`Punch.assets`), checked at compile time:
  # `Punch.asset("app.css")` is an `Asset::Stylesheet`.
  macro asset(name)
    {% raise "Punch.asset takes a string literal, the file's path in the asset directory" unless name.is_a?(StringLiteral) %}
    {% names = @top_level.has_constant?("PunchAssetNames") ? ::PunchAssetNames : [] of StringLiteral %}
    {% unless names.includes?(name) %}
      {% raise "Punch.asset: no asset #{name}#{names.empty? ? " (the app declares no asset directory: Punch.assets \"assets\")".id : "".id}" %}
    {% end %}
    {% if name.ends_with?(".css") %}
      ::Punch::Asset::Stylesheet.new({{ name }})
    {% elsif name.ends_with?(".js") %}
      ::Punch::Asset::Script.new({{ name }})
    {% else %}
      ::Punch::Asset::Static.new({{ name }})
    {% end %}
  end

  # Serves the embedded assets (`Punch.assets`) and Turbo, and writes what a
  # document's head needs to load them (`View#document`). Fingerprints, the
  # rewritten stylesheets, and compressed copies are computed once, on first
  # use (`Assets.table`).
  module Assets
    # The URL prefix of every asset.
    PREFIX = "/assets/"

    # What Punch serves, by extension: the content type, and whether a
    # gzip copy is worth keeping.
    TYPES = {
      "css"         => {"text/css; charset=utf-8", true},
      "js"          => {"text/javascript; charset=utf-8", true},
      "json"        => {"application/json", true},
      "map"         => {"application/json", true},
      "txt"         => {"text/plain; charset=utf-8", true},
      "svg"         => {"image/svg+xml", true},
      "ico"         => {"image/vnd.microsoft.icon", true},
      "webmanifest" => {"application/manifest+json", true},
      "png"         => {"image/png", false},
      "jpg"         => {"image/jpeg", false},
      "jpeg"        => {"image/jpeg", false},
      "gif"         => {"image/gif", false},
      "webp"        => {"image/webp", false},
      "avif"        => {"image/avif", false},
      "woff2"       => {"font/woff2", false},
      "woff"        => {"font/woff", false},
    }

    # Assets never change under a URL, so browsers and proxies keep them.
    CACHE_CONTROL = "public, max-age=31536000, immutable"

    # Turbo's module name in the import map, and its asset.
    TURBO = "@hotwired/turbo"

    # The script a document that morphs its refreshes loads beside Turbo
    # (`View#document(morph: true)`): a refresh keeps the value of the
    # field the viewer is typing in, which Turbo's morph would otherwise
    # reset to the server's. Turbo has no setting for this; the cancelable
    # `turbo:before-morph-attribute` event is its extension point.
    MORPH        = "punch/morph.js"
    MORPH_SOURCE = <<-JS
      // Keeps what the viewer is typing when Turbo morphs a page refresh.
      addEventListener("turbo:before-morph-attribute", (event) => {
        if (event.detail.attributeName === "value" && event.target === document.activeElement) event.preventDefault()
      })
      JS

    # The script of upload fields (`Punch::Upload::Ticket` in a form,
    # docs/uploads.md), which documents load when the app declares kinds
    # of upload. On a file control with `data-punch-upload` (the path of
    # the app's granting Command) it asks for a grant, sends the file to
    # the storage, asks Punch to check it, and puts the ticket into the
    # hidden field the control names. While it works, and after a
    # failure, the control is invalid, so the form is not sent without
    # the file; the control's `data-punch-upload-state` is `uploading`,
    # `uploaded`, or `failed`, and it fires `punch:upload` events.
    UPLOADS        = "punch/uploads.js"
    UPLOADS_SOURCE = <<-JS
      // Sends files straight to the storage (lib/punch/docs/uploads.md).
      const json = async (url, body) => {
        const response = await fetch(url, {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", Accept: "application/json" },
          body: JSON.stringify(body),
        })
        const answer = await response.json().catch(() => ({}))
        if (!response.ok) throw new Error(answer.errors?.[0]?.message || answer.detail || answer.title || response.statusText)
        return answer
      }

      const settle = (input, state, message) => {
        input.dataset.punchUploadState = state
        input.setCustomValidity(message)
        input.dispatchEvent(new CustomEvent("punch:upload", { bubbles: true, detail: { state, message } }))
      }

      addEventListener("change", async (event) => {
        const input = event.target
        if (!(input instanceof HTMLInputElement) || input.type !== "file" || !input.dataset.punchUpload) return
        const ticket = document.getElementById(input.dataset.punchUploadTicket)
        if (!ticket) return
        ticket.value = ""
        const file = input.files[0]
        if (!file) return settle(input, "", "")

        const attempt = (input.punchUploadAttempt || 0) + 1
        input.punchUploadAttempt = attempt
        settle(input, "uploading", input.dataset.punchUploadBusy || "Uploading…")
        try {
          const grant = await json(input.dataset.punchUpload, { size: file.size, content_type: file.type || "application/octet-stream", filename: file.name })
          const headers = Object.fromEntries(Object.entries(grant.headers).filter(([name]) => name.toLowerCase() !== "content-length"))
          const sent = await fetch(grant.url, { method: grant.method, headers, body: file, credentials: "omit" })
          if (!sent.ok) throw new Error(input.dataset.punchUploadFailed || "The upload failed.")
          await json(grant.check, { ticket: grant.ticket })
          if (input.punchUploadAttempt !== attempt) return
          ticket.value = grant.ticket
          settle(input, "uploaded", "")
        } catch (error) {
          if (input.punchUploadAttempt === attempt) settle(input, "failed", error.message || input.dataset.punchUploadFailed || "The upload failed.")
        }
      })
      JS

    # One served file.
    class Entry
      getter name : String
      getter url : String
      getter content_type : String
      getter body : String
      # A gzip copy, when it is smaller.
      getter gzip : String?

      def initialize(@name : String, @url : String, @content_type : String, @body : String, @gzip : String?)
      end

      def module? : Bool
        @name.ends_with?(".js")
      end
    end

    # Every asset with its URL, and the import map, computed once.
    class Table
      getter entries = {} of String => Entry
      getter by_url = {} of String => Entry
      # References in stylesheets that name no asset: `{stylesheet, reference}`.
      getter unresolved = [] of {String, String}
      # The import map as written into every document: one JSON line.
      getter import_map : String
      # The CSP source that allows that one inline script.
      getter import_map_source : String

      def initialize(sources : Hash(String, String))
        sources.each_key { |name| build(name, sources, Set(String).new) }
        @import_map = JSON.build do |json|
          json.object do
            json.field "imports" do
              json.object do
                @entries.values.select(&.module?).sort_by!(&.name).each do |entry|
                  json.field entry.name.rchop(".js"), entry.url
                end
              end
            end
          end
        end
        @import_map_source = "'sha256-#{Base64.strict_encode(Digest::SHA256.digest(@import_map))}'"
        @csp = "script-src 'self' #{@import_map_source}; style-src 'self' #{Turbo::PROGRESS_BAR_STYLE}"
        @content_security_policy = HTTP::SecurityHeaders::CSP % @csp
      end

      # `Assets.csp`.
      getter csp : String
      # The whole default Content-Security-Policy, with `csp` in it.
      getter content_security_policy : String

      def fetch(name : String) : Entry
        @entries[name]? || raise KeyError.new("no asset #{name}")
      end

      private def build(name : String, sources : Hash(String, String), building : Set(String)) : Entry
        if entry = @entries[name]?
          return entry
        end

        building << name
        body = sources[name]
        extension = name.rpartition('.').last.downcase
        content_type, compressible = TYPES[extension]
        body = rewrite(name, body, sources, building) if extension == "css"
        digest = Digest::SHA256.hexdigest(body)[0, 16]
        stem = name.rchop(".#{name.rpartition('.').last}")
        url = "#{PREFIX}#{stem}-#{digest}.#{name.rpartition('.').last}"
        entry = Entry.new(name, url, content_type, body, compressible ? Assets.gzip(body) : nil)
        building.delete(name)
        @by_url[url] = entry
        @entries[name] = entry
      end

      # `url(...)` and `@import "..."` in a stylesheet name other assets by
      # relative paths; they become the fingerprinted URLs, so the
      # stylesheet's own fingerprint follows theirs. Absolute URLs, `data:`,
      # and fragments stay; a reference to no asset stays and is listed in
      # `unresolved`.
      private def rewrite(name : String, css : String, sources : Hash(String, String), building : Set(String)) : String
        css.gsub(/url\(\s*(['"]?)([^'")\s]+)\1\s*\)|@import\s+(['"])([^'"]+)\3/) do |match, data|
          reference = data[2]? || data[4]
          target = resolve(name, reference)
          if target.nil?
            match
          elsif !sources.has_key?(target) || building.includes?(target)
            @unresolved << {name, reference}
            match
          else
            url = build(target, sources, building).url + reference[reference.split(/[?#]/, 2).first.size..]
            data[2]? ? "url(\"#{url}\")" : "@import \"#{url}\""
          end
        end
      end

      # The asset a relative reference in *from* names, or `nil` for one
      # that is not relative (absolute, with a scheme, or a fragment).
      private def resolve(from : String, reference : String) : String?
        return if reference.empty? || reference.starts_with?('/') || reference.starts_with?('#') || reference.includes?(':')

        path = reference.split(/[?#]/, 2).first
        parts = from.split('/')[0..-2]
        path.split('/').each do |part|
          case part
          when "", "." then next
          when ".." then parts.pop? || return "" # outside the directory: no asset
          else parts << part
          end
        end
        parts.join('/')
      end
    end

    @@sources : Hash(String, String) = {"#{TURBO}.js" => {{ read_file("#{__DIR__}/../../vendor/turbo/turbo.js") }}, MORPH => MORPH_SOURCE, UPLOADS => UPLOADS_SOURCE}
    @@table : Table?
    @@lock = Mutex.new
    # In a `punch dev` build: the asset directory, and how often the table
    # was built again from changed files since (`version`).
    @@directory : Directory?
    @@version = 0

    # A `punch dev` build's asset directory (`Assets.directory`): its files
    # as the compiler listed them, read again when one changed.
    class Directory
      # How long a look at the files counts: the table is asked for on every
      # page, and a look is one `stat` per file.
      FRESH = 200.milliseconds

      @checked : Time::Instant?
      @stamp = ""

      def initialize(@path : String, @names : Array(String))
      end

      # Puts the current contents into *sources* when a file changed since
      # the last look (the first look always reads them); whether it did.
      # A file removed since the build keeps what it last held: the next
      # build leaves it out.
      def read(sources : Hash(String, String), now : Time::Instant = Time.instant) : Bool
        return false if (checked = @checked) && now - checked < FRESH

        @checked = now
        stamp = String.build do |io|
          @names.each do |name|
            info = File.info?(File.join(@path, name))
            io << name << ':' << info.try(&.modification_time.to_unix_ns) << ':' << info.try(&.size) << '\n'
          end
        end
        return false if stamp == @stamp

        @stamp = stamp
        @names.each do |name|
          sources[name] = File.read(File.join(@path, name)) rescue next
        end
        true
      end
    end

    {% if flag?(:punch_dev) %}
      @@sources[Dev::SCRIPT] = Dev::SCRIPT_SOURCE
    {% end %}

    # :nodoc:
    # Called by `Punch.assets` at program start. A table built before (by
    # code that ran earlier at the top level) is built again on next use.
    def self.add(name : String, body : String) : Nil
      @@lock.synchronize do
        @@sources[name] = body
        @@table = nil
      end
    end

    # :nodoc:
    # Called by `Punch.assets` at program start in a `punch dev` build: the
    # files are read from *path* when the table is built, and again when
    # one changes.
    def self.directory(path : String, names : Array(String)) : Nil
      @@lock.synchronize do
        @@directory = Directory.new(path, names)
        @@table = nil
      end
    end

    # The assets with their fingerprints, built on first use; in a
    # `punch dev` build, built again when a file in the directory changed
    # (looked at no more than every 200 ms).
    def self.table : Table
      reread if @@directory
      @@table || @@lock.synchronize { @@table ||= Table.new(@@sources) }
    end

    # How often the table was built again from changed files: a page's
    # reload stream (`Dev`) compares it.
    def self.version : Int32
      @@version
    end

    private def self.reread : Nil
      @@lock.synchronize do
        directory = @@directory || return
        first = @@table.nil?
        next unless directory.read(@@sources)

        @@table = nil
        @@version += 1 unless first
      end
    end

    # Turbo, which every document loads unless told not to.
    def self.turbo : Asset::Script
      Asset::Script.new("#{TURBO}.js")
    end

    # The script that keeps a typed value through a morphing refresh
    # (`MORPH`).
    def self.morph : Asset::Script
      Asset::Script.new(MORPH)
    end

    # The script of upload fields (`UPLOADS`).
    def self.uploads : Asset::Script
      Asset::Script.new(UPLOADS)
    end

    # The sources the Content-Security-Policy must allow for scripts and
    # styles beyond `'self'`: the import map, and Turbo's progress bar.
    def self.csp : String
      table.csp
    end

    # The response for a path below `PREFIX`, or `nil` when no asset has
    # that URL (an old fingerprint included).
    def self.respond(context : HTTP::Context) : HTTP::Response?
      entry = table.by_url[context.request.path]? || return
      headers = ::HTTP::Headers{"Content-Type" => entry.content_type, "Cache-Control" => CACHE_CONTROL}
      body = entry.body
      if gzip = entry.gzip
        headers["Vary"] = "Accept-Encoding"
        if gzip?(context.request.headers["Accept-Encoding"]?)
          headers["Content-Encoding"] = "gzip"
          body = gzip
        end
      end
      if context.span.recording?
        context.span.name = "#{context.request.method} #{PREFIX}*"
        context.span.set("http.route", "#{PREFIX}*")
        context.span.set("punch.surface", "asset")
        context.span.set("punch.asset", entry.name)
      end
      HTTP::Response.new(:ok, body, headers)
    end

    # Whether `Accept-Encoding` allows gzip: `gzip` or `*` without `q=0`.
    def self.gzip?(header : String?) : Bool
      return false unless header

      header.split(',').any? do |item|
        coding, _, parameters = item.partition(';')
        next false unless coding.strip.downcase.in?("gzip", "*")
        quality = parameters.split(';').find(&.strip.downcase.starts_with?("q="))
        quality.nil? || (quality.strip[2..].to_f? || 0.0) > 0.0
      end
    end

    # :nodoc:
    def self.gzip(body : String) : String?
      compressed = String.build do |io|
        Compress::Gzip::Writer.open(io, level: Compress::Gzip::BEST_COMPRESSION) { |gzip| gzip << body }
      end
      compressed if compressed.bytesize < body.bytesize
    end
  end
end
