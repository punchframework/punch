require "uri"

module Punch
  @@public_url = "http://127.0.0.1:3000"

  # Where people reach the app, such as `https://invoices.example.org`,
  # without a trailing slash: the base of absolute links (`Href#absolute`)
  # in mail. Set at boot from `PUNCH_PUBLIC_URL` (`Punch::AppConfig`).
  def self.public_url : String
    @@public_url
  end

  # :nodoc:
  def self.public_url=(url : String) : String
    @@public_url = url
  end

  # The target of a link: a typed reference to a page, never a hand-written
  # URL. Made by `SomePage.href(...)`, which checks its parameters at
  # compile time, by `Href.external` for another site, or by
  # `Punch.asset(...).href` for an asset.
  #
  # ```
  # v.a "Invoice A-42", href: Billing::Invoices::ShowPage.href(invoice_id: id)
  # v.a "Crystal", href: Punch::Href.external("https://crystal-lang.org")
  # ```
  struct Href
    # Schemes an external link may use. `javascript:` and `data:` never
    # can, whatever the view is given.
    EXTERNAL_SCHEMES = {"https", "http", "mailto", "tel"}

    # The path and query, such as `/billing/invoices?after=42`, or the whole
    # URL of an external link.
    getter url : String
    # The page this link opens (`Billing::Invoices::ShowPage`); `nil` for an
    # external link.
    getter page : String?
    # The asset this links to (`Punch.asset("logo.svg").href`).
    getter asset : String?

    # Asks the page's policy whether the viewer may open it; `nil` for
    # external links and assets.
    # :nodoc:
    getter permit : Proc(Policy::Authorizer, Bool)?

    # Punch's own: a path or URL it built. Even so, a script URL is
    # refused, whoever passes it.
    # :nodoc:
    def initialize(@url : String, @page : String?, *, @asset : String? = nil, @permit : Proc(Policy::Authorizer, Bool)? = nil)
      if @url.lstrip(" \t\n\r\f\0").downcase.matches?(/\A(javascript|vbscript|data):/)
        raise ArgumentError.new("Punch::Href refuses a script URL: #{@url[0, 20].inspect}")
      end
    end

    # Characters that change how a URL reads without showing: bidi
    # controls, zero-width characters, the soft hyphen.
    INVISIBLE = /[\x{00AD}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2069}\x{FEFF}]/

    # A link to another site, such as `https://example.org/terms`. Raises
    # `ArgumentError` unless *url* is an absolute `https`, `http`, `mailto`,
    # or `tel` URL; for an address from user data use `external?`.
    def self.external(url : String) : self
      external?(url) || raise ArgumentError.new("not an external link: #{url.inspect}. Use an absolute https, http, mailto, or tel URL; link to pages with Page.href")
    end

    # Like `external`, but `nil` instead of raising, for addresses that
    # come from users.
    def self.external?(url : String) : self?
      return if url.each_char.any? { |char| char.ascii_whitespace? || char.ascii_control? }
      return if INVISIBLE.matches?(url)

      uri = URI.parse(url) rescue return
      scheme = uri.scheme.try(&.downcase) || return
      return unless EXTERNAL_SCHEMES.includes?(scheme)
      return if scheme.starts_with?("http") && uri.host.presence.nil?
      return if !scheme.starts_with?("http") && uri.path.empty?

      new(url, nil)
    end

    # A link to an element of the same page, `#invoices_42`.
    def self.fragment(id : String) : self
      new("##{URI.encode_path_segment(id)}", nil)
    end

    def external? : Bool
      @page.nil? && @asset.nil?
    end

    # The whole URL: *base* (`Punch.public_url`) before a page's or an
    # asset's path, for places outside the app's own pages, such as mail. An
    # external link stays as it is.
    def absolute(base : String = Punch.public_url) : String
      external? ? @url : "#{base}#{@url}"
    end

    # Where this link leads an agent reading markdown: an agent-readable
    # page's `.md` URL, anything else as it is. Markdown links, action
    # blocks, and redirects after an agent's form use it.
    def markdown_url : String
      Routing.markdown_url(self)
    end

    def to_s(io : IO) : Nil
      io << @url
    end
  end
end
