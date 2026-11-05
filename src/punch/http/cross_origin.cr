module Punch::HTTP
  # Cross-site request forgery, refused by request headers instead of form
  # tokens, as Go 1.25's `CrossOriginProtection` does.
  # Only Commands change state and none answers GET, so only unsafe methods
  # are checked:
  #
  # 1. `Sec-Fetch-Site: same-origin` or `none` (typed by the user) passes;
  #    any other value (`cross-site`, `same-site`) fails unless `Origin` is
  #    a trusted origin. Every current browser sends this header.
  # 2. Without it, an `Origin` whose host is the request's `Host` passes,
  #    as does a trusted origin; any other `Origin` fails.
  # 3. With neither header the request did not come from a current
  #    browser's page. It passes unless it carries the session cookie: an
  #    old browser (Internet Explorer, Edge's IE mode) sends neither header
  #    on a cross-site form, but does send the cookie.
  #
  # `same-site` fails because a sibling subdomain may be hostile. A request
  # with `Authorization: Bearer` is not checked: it carries no ambient
  # credentials, and the session cookie is ignored on it. Other schemes
  # (`Basic`) a browser may add by itself, so they are checked.
  module CrossOrigin
    SAFE = {"GET", "HEAD", "OPTIONS"}

    # Whether *request* may proceed. *trusted* holds origins such as
    # `https://admin.example.com`, lowercase, without a trailing slash.
    def self.allowed?(request : ::HTTP::Request, trusted : Set(String)) : Bool
      return true if SAFE.includes?(request.method)

      headers = request.headers
      return true if headers["Authorization"]?.try(&.starts_with?("Bearer "))

      origin = headers["Origin"]?
      if site = headers["Sec-Fetch-Site"]?
        return true if site == "same-origin" || site == "none"

        return trusted?(origin, trusted)
      end
      return !request.cookies.has_key?(Auth::COOKIE) unless origin
      return true if trusted?(origin, trusted)

      host = headers["Host"]? || return false
      origin_host(origin).try(&.compare(host, case_insensitive: true).zero?) || false
    end

    # The host and port of *origin* (`https://example.com:8443`), or `nil`
    # for `null` and anything that is not an origin.
    def self.origin_host(origin : String) : String?
      scheme, separator, host = origin.partition("://")
      return if separator.empty? || host.empty? || host.includes?('/')

      host if scheme.in?("http", "https")
    end

    # *origins* checked and normalized for `allowed?`.
    def self.normalize(origins : Enumerable(String)) : Set(String)
      origins.to_set do |origin|
        normalized = origin.downcase.rchop('/')
        raise ArgumentError.new("trusted origin must be scheme://host[:port], got #{origin.inspect}") unless origin_host(normalized)
        normalized
      end
    end

    private def self.trusted?(origin : String?, trusted : Set(String)) : Bool
      !!origin && trusted.includes?(origin.downcase)
    end
  end
end
