require "http/client"
require "../s3"

module Punch::Backup
  # Whether the replica's bucket encrypts what Litestream uploads
  # (Litestream 0.5 does not encrypt, so bucket-side encryption is
  # required). Asks the bucket for its default encryption with S3's
  # `GetBucketEncryption`, signed with AWS Signature Version 4
  # (`Punch::S3::SigV4`).
  module Encryption
    # The bucket encrypts new objects by default.
    record Encrypted, algorithm : String

    # The bucket has no default encryption.
    record Unencrypted

    # The bucket did not say: no keys, access denied, a provider without the
    # request, or no answer. *reason* says which; it never holds a key.
    record Unknown, reason : String

    # Not asked: a file replica, or the operator stated the provider
    # encrypts (`PUNCH_BACKUP_ENCRYPTION=provider`).
    record NotChecked, reason : String

    alias Result = Encrypted | Unencrypted | Unknown | NotChecked

    # The answer for *config*'s bucket. *env* holds the keys
    # (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, or
    # Litestream's `LITESTREAM_` ones) and the default region (`AWS_REGION`).
    def self.check(config : Config, env = ENV, timeout : Time::Span = 10.seconds, now : Time = Time.utc) : Result
      url = config.url
      return NotChecked.new("no replica") unless url
      return NotChecked.new("file replica") unless config.s3?
      return NotChecked.new("PUNCH_BACKUP_ENCRYPTION=provider") if config.encryption.provider?

      key = env["AWS_ACCESS_KEY_ID"]?.presence || env["LITESTREAM_ACCESS_KEY_ID"]?.presence
      secret = env["AWS_SECRET_ACCESS_KEY"]?.presence || env["LITESTREAM_SECRET_ACCESS_KEY"]?.presence
      return Unknown.new("no S3 keys in the environment (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)") unless key && secret

      bucket = Bucket.new(url, env)
      credentials = S3::SigV4::Credentials.new(key, secret, env["AWS_SESSION_TOKEN"]?.presence)
      status, headers, body = bucket.get_encryption(credentials, timeout, now)
      # A bucket in another region than the one assumed: AWS names it.
      if status.in?(301, 400) && (region = Encryption.region(headers)) && region != bucket.region
        bucket = bucket.in_region(region)
        status, _, body = bucket.get_encryption(credentials, timeout, now)
      end
      interpret(status, body)
    rescue ex : IO::Error | Socket::Error | OpenSSL::Error
      Unknown.new("#{ex.class.name}: #{ex.message}")
    end

    # The region a redirect names, if it is a region name: the header comes
    # from the network, before any signature, and goes into a URL.
    # :nodoc:
    def self.region(headers : ::HTTP::Headers) : String?
      headers["x-amz-bucket-region"]?.try { |region| region if region.matches?(/\A[a-z0-9-]{1,32}\z/) }
    end

    # The result of an answer with *status* and *body*.
    def self.interpret(status : Int32, body : String) : Result
      code = body[/<Code>([^<]*)<\/Code>/, 1]?
      if status == 200
        algorithm = body[/<SSEAlgorithm>([^<]*)<\/SSEAlgorithm>/, 1]?
        return algorithm ? Encrypted.new(algorithm) : Unencrypted.new
      end
      return Unencrypted.new if code == "ServerSideEncryptionConfigurationNotFoundError"

      Unknown.new("GetBucketEncryption answered #{status}#{code ? " #{code}" : ""}")
    end

    # Where the bucket is reached, from the replica URL and its
    # Litestream options (`endpoint`, `region`, `forcePathStyle`).
    struct Bucket
      getter name : String
      getter region : String
      getter endpoint : URI
      getter? path_style : Bool

      def initialize(url : URI, env)
        @name = url.host || raise ArgumentError.new("no bucket in #{url}")
        query = url.query_params
        @region = query["region"]?.presence || env["AWS_REGION"]?.presence || env["AWS_DEFAULT_REGION"]?.presence || "us-east-1"
        if endpoint = query["endpoint"]?.presence
          @endpoint = URI.parse(endpoint)
          # As Litestream: a custom endpoint uses path style unless told not to.
          @path_style = query["forcePathStyle"]? != "false"
        else
          @endpoint = URI.parse("https://s3.#{@region}.amazonaws.com")
          @path_style = query["forcePathStyle"]? == "true"
        end
      end

      protected def initialize(@name, @region, @endpoint, @path_style)
      end

      # The same bucket in *region*, for AWS's own endpoints.
      def in_region(region : String) : Bucket
        endpoint = @endpoint.host.try(&.ends_with?(".amazonaws.com")) ? URI.parse("https://s3.#{region}.amazonaws.com") : @endpoint
        Bucket.new(@name, region, endpoint, @path_style)
      end

      # Status, headers, and body of `GET /?encryption`.
      def get_encryption(credentials : S3::SigV4::Credentials, timeout : Time::Span, now : Time) : {Int32, ::HTTP::Headers, String}
        host = @path_style ? @endpoint.host.to_s : "#{@name}.#{@endpoint.host}"
        port = @endpoint.port
        authority = port ? "#{host}:#{port}" : host
        path = @path_style ? "/#{URI.encode_path_segment(@name)}" : "/"
        tls = @endpoint.scheme != "http"
        headers = S3::SigV4.sign("GET", authority, path, {"encryption" => ""}, ::HTTP::Headers.new,
          credentials, @region, "s3", now)
        client = ::HTTP::Client.new(host, port, tls: tls)
        client.connect_timeout = timeout
        client.read_timeout = timeout
        begin
          response = client.get("#{path}?encryption=", headers: headers)
          {response.status_code, response.headers, response.body}
        ensure
          client.close
        end
      end
    end
  end
end
