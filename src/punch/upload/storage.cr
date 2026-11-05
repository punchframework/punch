require "crypto/subtle"
require "../s3"

module Punch::Upload
  # Where the bytes are: an S3 bucket, or a local directory in development.
  # Object keys are `<prefix>pending/<id>` for what a client sent and
  # `<prefix>files/<kind>/<id>` for checked copies; only the latter are
  # ever served.
  abstract class Storage
    # How long a client has to send the file once granted.
    PUT_EXPIRY = 10.minutes

    getter prefix : String

    def initialize(@prefix : String)
    end

    def pending_key(id : String) : String
      "#{@prefix}pending/#{id}"
    end

    def file_key(key : Key) : String
      "#{@prefix}files/#{key.value}"
    end

    # The URL and headers of a `PUT` of exactly *size* bytes of
    # *content_type* to *object*, valid for `PUT_EXPIRY`.
    abstract def presign_put(object : String, size : Int64, content_type : String, now : Time) : {String, Hash(String, String)}

    # A URL that fetches *object* until *expires* from *now*.
    abstract def presign_get(object : String, now : Time, expires : Time::Span, download : String?) : String

    abstract def head(object : String) : S3::Head?
    abstract def read_start(object : String, bytes : Int32, etag : String) : Bytes
    abstract def copy(from : String, to : String, *, etag : String, content_type : String, disposition : String) : Nil
    abstract def delete(object : String) : Nil

    # The CSP source pages must be allowed to send files to and show them
    # from, beyond their own (`connect-src`, `img-src`, `media-src`): as
    # narrow as the storage's URLs allow. `nil` for the app's own origin.
    abstract def csp_source : String?

    # The `Content-Disposition` of a file of *content_type*: shown where
    # browsers show such files safely, downloaded otherwise.
    def self.disposition(content_type : String) : String
      TYPES[content_type]?.try(&.inline) ? "inline" : "attachment"
    end
  end

  # An S3-compatible bucket.
  class S3Storage < Storage
    getter bucket : S3::Bucket

    def initialize(@bucket : S3::Bucket, @credentials : S3::SigV4::Credentials, prefix : String, @timeout : Time::Span = 10.seconds)
      super(prefix)
      @client = S3::Client.new(@bucket, @credentials, @timeout)
    end

    def presign_put(object : String, size : Int64, content_type : String, now : Time) : {String, Hash(String, String)}
      headers = ::HTTP::Headers{"Content-Length" => size.to_s, "Content-Type" => content_type}
      url = @bucket.presign("PUT", object, @credentials, now: now, expires: PUT_EXPIRY, headers: headers)
      {url, {"Content-Type" => content_type, "Content-Length" => size.to_s}}
    end

    def presign_get(object : String, now : Time, expires : Time::Span, download : String?) : String
      query = {} of String => String
      query["response-content-disposition"] = Upload.attachment(download) if download
      @bucket.presign("GET", object, @credentials, now: now, expires: expires, query: query)
    end

    def head(object : String) : S3::Head?
      @client.head(object)
    end

    def read_start(object : String, bytes : Int32, etag : String) : Bytes
      @client.read_start(object, bytes, etag)
    end

    def copy(from : String, to : String, *, etag : String, content_type : String, disposition : String) : Nil
      @client.copy(from, to, etag: etag, content_type: content_type, disposition: disposition)
    end

    def delete(object : String) : Nil
      @client.delete(object)
    end

    def csp_source : String?
      @bucket.csp_source(@prefix)
    end
  end

  # A directory, for development and test (`storage: local`): the app
  # answers the signed `PUT` and `GET` itself, below `LOCAL_PATH`, with
  # the checks a bucket makes (signature, expiry, size, type). Boot
  # refuses it in other environments.
  class LocalStorage < Storage
    # *key* signs URLs; a new one per process, as URLs live minutes.
    # Without *directory*, `uploads` in `PUNCH_STORAGE`, looked up when
    # first used, since the credentials load before the storage is known.
    def initialize(@directory : String? = nil, prefix : String = "", @key : Bytes = Random::Secure.random_bytes(32))
      super(prefix)
    end

    def directory : String
      @directory ||= ::File.join(Backup.storage || raise(Credentials::NotLoaded.new("Local uploads need PUNCH_STORAGE: serve and jobs set it at boot")), "uploads")
    end

    def presign_put(object : String, size : Int64, content_type : String, now : Time) : {String, Hash(String, String)}
      url = signed_url("PUT", object, now + PUT_EXPIRY, {"size" => size.to_s, "type" => content_type})
      {url, {"Content-Type" => content_type, "Content-Length" => size.to_s}}
    end

    def presign_get(object : String, now : Time, expires : Time::Span, download : String?) : String
      params = {} of String => String
      params["download"] = download if download
      signed_url("GET", object, now + expires, params)
    end

    # The parameters of a signed URL for *object*, if its signature is
    # right and it has not expired.
    def verify(method : String, object : String, query : URI::Params, now : Time) : Hash(String, String)?
      signature = query["signature"]? || return
      expires = query["expires"]?.try(&.to_i64?) || return
      return if now.to_unix > expires

      params = {} of String => String
      query.each { |name, value| params[name] = value unless name.in?("signature", "expires") }
      expected = signature(method, object, expires, params)
      ::Crypto::Subtle.constant_time_compare(expected, signature) ? params : nil
    end

    def head(object : String) : S3::Head?
      path = path(object)
      info = ::File.info?(path) || return
      meta = meta(object)
      S3::Head.new(info.size, meta["type"]?, meta["etag"]? || "")
    end

    def read_start(object : String, bytes : Int32, etag : String) : Bytes
      raise S3::Error.new("GET answered 412 PreconditionFailed", 412) unless head(object).try(&.etag) == etag

      ::File.open(path(object)) do |file|
        buffer = Bytes.new(bytes)
        buffer[0, file.read(buffer)]
      end
    end

    def copy(from : String, to : String, *, etag : String, content_type : String, disposition : String) : Nil
      raise S3::Error.new("COPY answered 412 PreconditionFailed", 412) unless head(from).try(&.etag) == etag

      Dir.mkdir_p(::File.dirname(path(to)), 0o700)
      ::File.copy(path(from), path(to))
      write_meta(to, content_type, etag, disposition)
    end

    def delete(object : String) : Nil
      ::File.delete?(path(object))
      ::File.delete?(meta_path(object))
    end

    def csp_source : String?
      nil
    end

    # Writes what a client sent to *object*: at most *size* bytes from
    # *body*. Whether exactly *size* arrived; anything else is removed.
    def write(object : String, body : IO, size : Int64, content_type : String) : Bool
      path = path(object)
      Dir.mkdir_p(::File.dirname(path), 0o700)
      written = ::File.open(path, "w", 0o600) { |file| IO.copy(body, file, size + 1) }
      unless written == size
        delete(object)
        return false
      end
      write_meta(object, content_type, %("#{Random::Secure.hex(16)}"), nil)
      true
    end

    # The bytes, type, and disposition of a checked file.
    def file(object : String) : {String, String, String}?
      path = path(object)
      return unless ::File.file?(path)

      meta = meta(object)
      {path, meta["type"]? || "application/octet-stream", meta["disposition"]? || "attachment"}
    end

    private def signed_url(method : String, object : String, expires : Time, params : Hash(String, String)) : String
      seconds = expires.to_unix
      query = URI::Params.build do |form|
        params.each { |name, value| form.add(name, value) }
        form.add("expires", seconds.to_s)
        form.add("signature", signature(method, object, seconds, params))
      end
      "#{LOCAL_PATH}#{S3.path(object)}?#{query}"
    end

    private def signature(method : String, object : String, expires : Int64, params : Hash(String, String)) : String
      text = String.build do |io|
        io << method << '\n' << object << '\n' << expires
        params.to_a.sort!.each { |name, value| io << '\n' << name << '=' << value }
      end
      OpenSSL::HMAC.hexdigest(:sha256, @key, text)
    end

    private def path(object : String) : String
      raise ArgumentError.new("not an object key: #{object.inspect}") unless Storage.valid_object?(object)

      ::File.join(directory, object)
    end

    private def meta_path(object : String) : String
      path(object) + ".meta"
    end

    private def meta(object : String) : Hash(String, String)
      Hash(String, String).from_json(::File.read(meta_path(object)))
    rescue IO::Error | JSON::ParseException
      {} of String => String
    end

    private def write_meta(object : String, content_type : String, etag : String, disposition : String?) : Nil
      meta = {"type" => content_type, "etag" => etag}
      meta["disposition"] = disposition if disposition
      ::File.write(meta_path(object), meta.to_json, perm: 0o600)
    end
  end

  # Whether *object* is a key Punch writes: `pending/<id>` or
  # `files/<kind>/<id>` below a prefix of plain segments. Nothing else is
  # read or written in the local directory.
  def Storage.valid_object?(object : String) : Bool
    object.valid_encoding? && object.matches?(/\A(?:[a-z0-9_.-]+\/)*(?:pending\/[a-z2-7]{26}|files\/[a-z0-9_]+(?:\.[a-z0-9_]+)*\/[a-z2-7]{26})\z/) &&
      !object.split('/').any?(&.in?(".", ".."))
  end

  # Whether *object* is what a client sends (`pending/<id>`), never served.
  def Storage.pending?(object : String) : Bool
    object.valid_encoding? && object.matches?(/(?:\A|\/)pending\/[a-z2-7]{26}\z/)
  end

  # A `Content-Disposition` that downloads the file as *name*, with its
  # characters RFC 6266 and RFC 8187 can carry.
  def self.attachment(name : String) : String
    name = name.scrub
    plain = name.gsub(/[^A-Za-z0-9._ -]/, "_").strip
    plain = "download" if plain.empty?
    %(attachment; filename="#{plain}"; filename*=UTF-8''#{S3.encode(name)})
  end
end
