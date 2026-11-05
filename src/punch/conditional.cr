require "base64"
require "digest/sha256"

module Punch
  # A result that knows its version. A Query whose result includes it
  # answers `GET` with an `ETag`, and with `304 Not Modified` when the
  # client's `If-None-Match` names the current one. The version is whatever
  # changes whenever the content does: an `updated_at`, a revision number,
  # the newest of several timestamps.
  #
  # ```
  # struct InvoiceView
  #   include JSON::Serializable
  #   include Punch::HTTP::Versioned
  #
  #   getter id : Invoices::ID
  #   getter updated_at : Time
  #
  #   def version : Time
  #     updated_at
  #   end
  # end
  # ```
  module HTTP::Versioned
    abstract def version : String | Int64 | Int32 | Time
  end

  # Turns versions into entity tags and checks `If-None-Match` (RFC 9110,
  # 13.1.2). Tags are weak: they name a version, not exact bytes.
  module HTTP::Conditional
    # Results whose content differs for the same version must not share a
    # tag, so the tag covers the result type, the signed-in user, and the
    # binary that renders it.
    def self.etag(type_name : String, version : String | Int64 | Int32 | Time, user_id : Int64?) : String
      text = version.is_a?(Time) ? version.to_utc.to_rfc3339(fraction_digits: 9) : version.to_s
      digest = Digest::SHA256.digest("#{build}\0#{type_name}\0#{user_id}\0#{text}")
      %(W/"#{Base64.urlsafe_encode(digest[0, 16], padding: false)}")
    end

    # Whether *request*'s `If-None-Match` names *etag* (weak comparison) or
    # is `*`.
    def self.match?(request : ::HTTP::Request, etag : String) : Bool
      header = request.headers.get?("If-None-Match") || return false
      opaque = etag.lchop("W/")
      header.any? do |line|
        line.split(',').any? do |candidate|
          candidate = candidate.strip
          candidate == "*" || candidate.lchop("W/") == opaque
        end
      end
    end

    # `Cache-Control` of a tagged response: any cache may keep it but must
    # ask before reusing it, and shared caches must not, since results may
    # depend on the actor.
    CACHE_CONTROL = "private, no-cache"

    # *response* with its tag, or 304 when the request already has it.
    # Only `GET` and `HEAD` are conditional here.
    def self.respond(context : HTTP::Context, etag : String, & : -> HTTP::Response) : HTTP::Response
      return yield unless context.request.method.in?("GET", "HEAD")

      if match?(context.request, etag)
        context.span.set("punch.outcome", "not_modified")
        response = HTTP::Response.new(:not_modified)
      else
        response = yield
      end
      response.headers["ETag"] = etag
      response.headers["Cache-Control"] = CACHE_CONTROL
      response
    end

    @@build : String?

    # Identifies the running binary by its path, size, and modification
    # time, so two processes of one deployment agree and a new deployment
    # changes every tag. Random when the executable cannot be found.
    def self.build : String
      @@build ||= begin
        path = Process.executable_path
        info = path.try { |found| File.info?(found) }
        if path && info
          Digest::SHA256.hexdigest("#{path}\0#{info.size}\0#{info.modification_time.to_unix_ns}")[0, 16]
        else
          Random::Secure.hex(8)
        end
      end
    end
  end
end
