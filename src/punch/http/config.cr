module Punch::HTTP
  # Server settings. The defaults are meant for production behind a reverse
  # proxy that terminates TLS.
  struct Config
    # Request bodies above this size are refused unless an operation raises
    # its limit. Uploads are not part of 1.0.
    DEFAULT_MAX_BODY_SIZE = 1 * 1024 * 1024

    # File descriptors kept for everything but connections: database
    # files and their WAL, logs, Litestream, outgoing requests.
    FD_RESERVE = 128

    getter host : String
    getter port : Int32
    getter max_body_size : Int32
    # How long a connection may be silent: while idle between requests and
    # while sending a request. Longer than the idle timeout of the proxy's
    # connection pool (kamal-proxy: 90 s), so that the proxy closes first.
    getter read_timeout : Time::Span
    getter write_timeout : Time::Span
    # How long shutdown keeps accepting after `/up` turns 503, so that a load
    # balancer that polls `/up` stops sending traffic first. 0 when the
    # proxy takes the app out of rotation before stopping it, as
    # kamal-proxy does on deploy.
    getter drain_delay : Time::Span
    # How long shutdown waits for requests in progress.
    getter shutdown_timeout : Time::Span
    getter max_request_line_size : Int32
    getter max_headers_size : Int32
    getter trusted_proxies : TrustedProxies
    getter security_headers : SecurityHeaders
    # Other origins whose pages may send Commands here, such as
    # `https://admin.example.com` (`CrossOrigin`). The app's own origin
    # needs no entry.
    getter trusted_origins : Set(String)
    # How many connections may be open at once; the server stops
    # accepting until one closes. By default the process's file
    # descriptor limit less `FD_RESERVE`.
    getter max_connections : Int32
    # How requests for paths only scanners ask for are answered, and when
    # an address is banned (`Probes`).
    getter probes : Probes::Settings

    def initialize(*, @host = "127.0.0.1", @port = 3000,
                   @max_body_size = DEFAULT_MAX_BODY_SIZE,
                   @read_timeout = 120.seconds, @write_timeout = 30.seconds,
                   @drain_delay = 0.seconds, @shutdown_timeout = 25.seconds,
                   @max_request_line_size = ::HTTP::MAX_REQUEST_LINE_SIZE,
                   @max_headers_size = ::HTTP::MAX_HEADERS_SIZE,
                   @trusted_proxies = TrustedProxies.none,
                   @security_headers = SecurityHeaders.new,
                   trusted_origins : Enumerable(String) = [] of String,
                   @max_connections = Config.connection_limit,
                   @probes = Probes::Settings.new)
      @trusted_origins = CrossOrigin.normalize(trusted_origins)
      raise ArgumentError.new("max_body_size must be positive") unless max_body_size > 0
      raise ArgumentError.new("max_connections must be positive") unless max_connections > 0
    end

    # The process's soft limit on open files (`RLIMIT_NOFILE`) less
    # `FD_RESERVE`, at least 16 and at most 65,536.
    def self.connection_limit : Int32
      limit = LibC::Rlimit.new
      return 1024 - FD_RESERVE unless LibC.getrlimit(LibC::RLIMIT_NOFILE, pointerof(limit)) == 0

      (limit.rlim_cur.to_u64 - {limit.rlim_cur.to_u64, FD_RESERVE.to_u64}.min).clamp(16_u64, 65_536_u64).to_i32
    end
  end

  # Headers added to every response that does not set them itself.
  struct SecurityHeaders
    # The Content-Security-Policy, without what `content_security_policy`
    # adds for the import map and Turbo (`Punch::Assets.csp`).
    CSP = "default-src 'self'; %s; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'"

    DEFAULTS = {
      "X-Content-Type-Options"       => "nosniff",
      "X-Frame-Options"              => "DENY",
      "Referrer-Policy"              => "strict-origin-when-cross-origin",
      "Cross-Origin-Opener-Policy"   => "same-origin",
      "Cross-Origin-Resource-Policy" => "same-origin",
      "Cache-Control"                => "no-store",
      # Features a page could ask the browser for, none of them used.
      "Permissions-Policy" => "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
    }

    # Sent only on requests that arrived over HTTPS through a trusted proxy.
    # Without `includeSubDomains`, which would bind every subdomain.
    DEFAULT_HSTS = "max-age=63072000"

    # The headers besides the Content-Security-Policy, which `server`
    # adds per response unless the app replaced it (`default_csp?`).
    getter headers : Hash(String, String)
    getter hsts : String?
    # Whether the default Content-Security-Policy is sent. It is read from
    # the asset table for every response, because the import map's hash is
    # known only once every asset is registered.
    getter? default_csp : Bool

    # Scripts, styles, and everything else from this origin only; the one
    # inline script (the import map) and the one inline style (Turbo's
    # progress bar) by their hashes. No inline handlers or `style`
    # attributes, no plugins, no `<base>`, no framing, forms only to this
    # origin. With uploads to a bucket, its origin for sending files and
    # showing them (`connect-src`, `img-src`, `media-src`).
    def self.content_security_policy : String
      Punch::Upload.content_security_policy(Punch::Assets.table.content_security_policy)
    end

    # *overrides* replace defaults by name; a `nil` value removes a header.
    def initialize(overrides : Hash(String, String?) = {} of String => String?, @hsts : String? = DEFAULT_HSTS)
      @headers = DEFAULTS.dup
      @default_csp = !overrides.has_key?("Content-Security-Policy")
      overrides.each do |name, value|
        value ? (@headers[name] = value) : @headers.delete(name)
      end
    end
  end
end
