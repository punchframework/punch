require "http/client"
require "openssl/hmac"
require "digest/sha256"
require "uri"
require "./trace"

module Punch
  # As much of S3's REST API as Punch uses: AWS Signature Version 4, for
  # signed requests and presigned URLs, and the object requests that
  # uploads need (`docs/uploads.md`). The backup's encryption check
  # (`Backup::Encryption`) signs with it too. Any S3-compatible storage
  # works: AWS, Cloudflare R2, Backblaze B2, Hetzner, MinIO, and others.
  module S3
    # A request the storage refused, or an answer Punch cannot read. The
    # message holds the status and S3's error code, never a key or a URL's
    # signature.
    class Error < Exception
      getter status : Int32

      def initialize(message : String, @status : Int32 = 0)
        super(message)
      end
    end

    # AWS Signature Version 4.
    module SigV4
      record Credentials, key : String, secret : String, session_token : String? do
        def inspect(io : IO) : Nil
          io << "SigV4::Credentials(" << key << ", [secret])"
        end

        def to_s(io : IO) : Nil
          inspect(io)
        end
      end

      ALGORITHM  = "AWS4-HMAC-SHA256"
      EMPTY_HASH = Digest::SHA256.hexdigest("")
      # The payload hash of a presigned URL: the signature does not cover
      # the body, whose size and type are covered by signed headers.
      UNSIGNED = "UNSIGNED-PAYLOAD"
      # The longest a presigned URL may live (AWS refuses longer).
      MAX_EXPIRY = 7.days

      # *headers* plus `Host`, `X-Amz-Date`, `X-Amz-Content-Sha256`, the
      # session token if any, and `Authorization`, for a request without a
      # body. *path* is the canonical path, each segment already encoded
      # (`S3.path`), and is sent as it is.
      def self.sign(method : String, authority : String, path : String, query : Hash(String, String),
                    headers : ::HTTP::Headers, credentials : Credentials, region : String, service : String,
                    now : Time) : ::HTTP::Headers
        stamp, date = stamps(now)
        signed = headers.dup
        signed["Host"] = authority
        signed["X-Amz-Date"] = stamp
        signed["X-Amz-Content-Sha256"] = EMPTY_HASH if service == "s3"
        credentials.session_token.try { |token| signed["X-Amz-Security-Token"] = token }
        canonical_headers, signed_names = canonical_headers(signed)
        scope = "#{date}/#{region}/#{service}/aws4_request"
        signature = signature(credentials, date, region, service, stamp, scope,
          canonical(method, path, canonical_query(query), canonical_headers, signed_names, EMPTY_HASH))
        signed["Authorization"] = "#{ALGORITHM} Credential=#{credentials.key}/#{scope}, SignedHeaders=#{signed_names}, Signature=#{signature}"
        signed
      end

      # The query string of a presigned URL for *method* on *path*: *query*
      # plus the signature's parameters. Every header in *headers* is signed
      # (with `Host`), so the request must send each with exactly that
      # value: a signed `Content-Length` makes the storage refuse a body of
      # any other size.
      def self.presign(method : String, authority : String, path : String, query : Hash(String, String),
                       headers : ::HTTP::Headers, credentials : Credentials, region : String, now : Time,
                       expires : Time::Span, service : String = "s3") : String
        raise ArgumentError.new("a presigned URL lives 1 second to 7 days, not #{expires}") unless 1.second <= expires <= MAX_EXPIRY

        stamp, date = stamps(now)
        signed = headers.dup
        signed["Host"] = authority
        canonical_headers, signed_names = canonical_headers(signed)
        scope = "#{date}/#{region}/#{service}/aws4_request"
        full = query.dup
        full["X-Amz-Algorithm"] = ALGORITHM
        full["X-Amz-Credential"] = "#{credentials.key}/#{scope}"
        full["X-Amz-Date"] = stamp
        full["X-Amz-Expires"] = expires.total_seconds.to_i.to_s
        full["X-Amz-SignedHeaders"] = signed_names
        credentials.session_token.try { |token| full["X-Amz-Security-Token"] = token }
        canonical_query = canonical_query(full)
        signature = signature(credentials, date, region, service, stamp, scope,
          canonical(method, path, canonical_query, canonical_headers, signed_names, UNSIGNED))
        "#{canonical_query}&X-Amz-Signature=#{signature}"
      end

      private def self.stamps(now : Time) : {String, String}
        stamp = now.to_utc.to_s("%Y%m%dT%H%M%SZ")
        {stamp, stamp[0, 8]}
      end

      private def self.canonical_headers(headers : ::HTTP::Headers) : {Array({String, String}), String}
        canonical = headers.map { |name, values| {name.downcase, values.join(',').strip.gsub(/\s+/, ' ')} }.sort_by!(&.[0])
        {canonical, canonical.join(';', &.[0])}
      end

      private def self.canonical_query(query : Hash(String, String)) : String
        query.map { |name, value| {S3.encode(name), S3.encode(value)} }.sort!.join('&') { |name, value| "#{name}=#{value}" }
      end

      private def self.canonical(method : String, path : String, query : String, headers : Array({String, String}),
                                 signed_names : String, payload : String) : String
        String.build do |io|
          io << method << '\n' << path << '\n' << query << '\n'
          headers.each { |name, value| io << name << ':' << value << '\n' }
          io << '\n' << signed_names << '\n' << payload
        end
      end

      private def self.signature(credentials : Credentials, date : String, region : String, service : String,
                                 stamp : String, scope : String, canonical : String) : String
        to_sign = "#{ALGORITHM}\n#{stamp}\n#{scope}\n#{Digest::SHA256.hexdigest(canonical)}"
        key = OpenSSL::HMAC.digest(:sha256, "AWS4#{credentials.secret}", date)
        key = OpenSSL::HMAC.digest(:sha256, key, region)
        key = OpenSSL::HMAC.digest(:sha256, key, service)
        key = OpenSSL::HMAC.digest(:sha256, key, "aws4_request")
        OpenSSL::HMAC.hexdigest(:sha256, key, to_sign)
      end
    end

    # RFC 3986 unreserved characters stay; everything else is %XX, as
    # Signature Version 4 wants it.
    def self.encode(text : String) : String
      String.build do |io|
        text.each_byte do |byte|
          char = byte.unsafe_chr
          if char.ascii_alphanumeric? || char.in?('-', '_', '.', '~')
            io << char
          else
            io << '%' << byte.to_s(16, upcase: true).rjust(2, '0')
          end
        end
      end
    end

    # *key* as a path: each segment encoded, the slashes kept.
    def self.path(key : String) : String
      key.split('/').join('/') { |segment| encode(segment) }
    end

    # A bucket and where it is reached.
    struct Bucket
      getter name : String
      getter region : String
      getter endpoint : URI
      getter? path_style : Bool

      def initialize(@name : String, @region : String, @endpoint : URI, @path_style : Bool)
      end

      # The host requests go to: the endpoint's, with the bucket in front
      # unless the bucket is in the path.
      def host : String
        @path_style ? @endpoint.host.to_s : "#{@name}.#{@endpoint.host}"
      end

      # `host`, with the endpoint's port if it names one.
      def authority : String
        (port = @endpoint.port) ? "#{host}:#{port}" : host
      end

      def tls? : Bool
        @endpoint.scheme != "http"
      end

      # Where browsers send uploads and fetch files: the origin a page's
      # Content-Security-Policy must allow.
      def origin : String
        "#{tls? ? "https" : "http"}://#{authority}"
      end

      # The narrowest CSP source for the objects below *prefix*: with the
      # bucket in the host, its origin and the prefix; with the bucket in
      # the path, where other buckets share the host, the bucket's path
      # too, so a page allowed to reach this bucket reaches no other.
      def csp_source(prefix : String = "") : String
        path = @path_style ? "/#{S3.encode(@name)}/" : "/"
        prefix = S3.path(prefix)
        path == "/" && prefix.empty? ? origin : "#{origin}#{path}#{prefix}"
      end

      # The canonical path of *key* (or of the bucket, without one).
      def path(key : String? = nil) : String
        prefix = @path_style ? "/#{S3.encode(@name)}" : ""
        key ? "#{prefix}/#{S3.path(key)}" : (prefix.empty? ? "/" : prefix)
      end

      # A presigned URL for *method* on *key*.
      def presign(method : String, key : String, credentials : SigV4::Credentials, *, now : Time, expires : Time::Span,
                  headers : ::HTTP::Headers = ::HTTP::Headers.new, query : Hash(String, String) = {} of String => String) : String
        path = path(key)
        "#{origin}#{path}?#{SigV4.presign(method, authority, path, query, headers, credentials, @region, now, expires)}"
      end
    end

    # What `HEAD` says about an object.
    record Head, size : Int64, content_type : String?, etag : String

    # The object requests uploads make, each signed and each a client span.
    # A connection per request: they are few, and each is to a host that
    # may be far away.
    class Client
      getter bucket : Bucket

      def initialize(@bucket : Bucket, @credentials : SigV4::Credentials, @timeout : Time::Span = 10.seconds)
      end

      # The object's size, type, and ETag; `nil` when there is none.
      def head(key : String, now : Time = Time.utc) : Head?
        status, headers, _ = request("HEAD", key, now: now)
        return if status == 404
        raise error("HEAD", status, "") unless status == 200

        size = headers["Content-Length"]?.try(&.to_i64?) || raise Error.new("HEAD answered without a Content-Length", status)
        etag = headers["ETag"]? || raise Error.new("HEAD answered without an ETag", status)
        Head.new(size, headers["Content-Type"]?, etag)
      end

      # Up to *bytes* bytes from the start of the object, if it still has
      # the ETag *etag*.
      def read_start(key : String, bytes : Int32, etag : String, now : Time = Time.utc) : Bytes
        headers = ::HTTP::Headers{"Range" => "bytes=0-#{bytes - 1}", "If-Match" => etag}
        status, _, body = request("GET", key, headers: headers, now: now)
        raise error("GET", status, body) unless status.in?(200, 206)

        slice = body.to_slice
        slice.size > bytes ? slice[0, bytes] : slice
      end

      # Copies *from* to *to* inside the bucket, if *from* still has the
      # ETag *etag*, giving the copy *content_type* and *disposition*.
      def copy(from : String, to : String, *, etag : String, content_type : String, disposition : String, now : Time = Time.utc) : Nil
        headers = ::HTTP::Headers{
          "x-amz-copy-source"          => "/#{S3.encode(@bucket.name)}/#{S3.path(from)}",
          "x-amz-copy-source-if-match" => etag,
          "x-amz-metadata-directive"   => "REPLACE",
          "Content-Type"               => content_type,
          "Content-Disposition"        => disposition,
        }
        status, _, body = request("PUT", to, headers: headers, now: now)
        # S3 may answer 200 and still report an error in the body.
        raise error("COPY", status, body) if status != 200 || body.includes?("<Error>")
      end

      # Deletes the object; one that is not there is fine.
      def delete(key : String, now : Time = Time.utc) : Nil
        status, _, body = request("DELETE", key, now: now)
        raise error("DELETE", status, body) unless status.in?(200, 204, 404)
      end

      private def request(method : String, key : String, *, headers : ::HTTP::Headers = ::HTTP::Headers.new,
                          now : Time) : {Int32, ::HTTP::Headers, String}
        Trace.span("S3 #{method}", Trace::Kind::Client) do |span|
          span.set("http.request.method", method)
          span.set("server.address", @bucket.host)
          span.set("punch.s3.bucket", @bucket.name)
          path = @bucket.path(key)
          signed = SigV4.sign(method, @bucket.authority, path, {} of String => String, headers, @credentials, @bucket.region, "s3", now)
          client = ::HTTP::Client.new(@bucket.host, @bucket.endpoint.port, tls: @bucket.tls?)
          client.connect_timeout = @timeout
          client.read_timeout = @timeout
          # The bytes as stored, whatever `Content-Encoding` an uploader set.
          client.compress = false
          begin
            response = case method
                       when "HEAD" then client.head(path, headers: signed)
                       when "GET"  then client.get(path, headers: signed)
                       when "PUT"  then client.put(path, headers: signed)
                       else             client.delete(path, headers: signed)
                       end
            span.set("http.response.status_code", response.status_code)
            span.error(response.status_code.to_s) if response.status_code >= 500
            {response.status_code, response.headers, response.body}
          ensure
            client.close
          end
        end
      end

      private def error(request : String, status : Int32, body : String) : Error
        code = body[/<Code>([^<]{1,64})<\/Code>/, 1]?
        Error.new("#{request} answered #{status}#{code ? " #{code}" : ""}", status)
      end
    end
  end
end
