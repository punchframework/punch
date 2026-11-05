module Punch::Upload
  # Where uploads are kept.
  enum StorageKind
    # An S3-compatible bucket (`Settings`): browsers upload to it directly.
    S3
    # A directory under `PUNCH_STORAGE`, served by the app itself with the
    # same signed URLs and the same checks; for development and test only.
    Local
  end

  # The app's upload settings, as a group in its credentials:
  #
  # ```
  # struct Invoicing::Credentials
  #   include Punch::Credentials
  #   getter uploads : Punch::Upload::Settings
  # end
  # ```
  #
  # ```yaml
  # uploads:
  #   storage: s3
  #   bucket: example-uploads
  #   endpoint: https://<account>.r2.cloudflarestorage.com   # AWS: leave out
  #   region: auto                                          # AWS: the bucket's region
  #   access_key_id: …
  #   secret_access_key: …
  # ```
  #
  # As every credential, each value can come from the environment:
  # `UPLOADS__STORAGE=local` in development.
  struct Settings
    include Credentials

    getter storage : StorageKind
    getter bucket : String?
    # The storage's endpoint, `https://` and a host. Without one, AWS's
    # endpoint for `region`.
    getter endpoint : String?
    getter region : String = "us-east-1"
    # The bucket in the path (`https://host/bucket/key`) instead of in the
    # host name; for MinIO and other stores without per-bucket host names.
    getter? path_style : Bool = false
    # Where in the bucket Punch's objects go, such as `invoicing/`: for a
    # bucket shared with other uses.
    getter prefix : String?
    getter access_key_id : String?
    getter secret_access_key : Secret(String)?

    # What is wrong with the settings, one line each; *field* is where
    # they are declared.
    def problems(field : String) : Array(String)
      problems = [] of String
      if (prefix = @prefix) && (!prefix.matches?(/\A(?:[a-z0-9_.-]+\/)+\z/) || prefix.split('/').any?(&.in?(".", "..")))
        problems << "#{field}.prefix must be lowercase letters, digits, '-', '_', '.', and '/', ending in '/', such as invoicing/"
      end
      return problems if @storage.local?

      {"bucket" => @bucket.presence, "access_key_id" => @access_key_id.presence, "secret_access_key" => @secret_access_key}.each do |name, value|
        problems << "#{field}.#{name} (#{Credentials.variable([field, name])}) must be set when #{field}.storage is s3" unless value
      end
      problems << "#{field}.region must be lowercase letters, digits, and '-'" unless @region.matches?(/\A[a-z0-9-]{1,32}\z/)
      if (bucket = @bucket.presence) && !bucket.matches?(/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/)
        problems << "#{field}.bucket must be a bucket name: lowercase letters, digits, '.', and '-'"
      end
      @endpoint.presence.try { |endpoint| endpoint_problem(field, endpoint) }.try { |problem| problems << problem }
      problems
    end

    private def endpoint_problem(field : String, endpoint : String) : String?
      uri = URI.parse(endpoint) rescue nil
      host = uri.try(&.host).presence
      if uri.nil? || host.nil? || !uri.path.in?("", "/") || uri.query || uri.user
        "#{field}.endpoint must be a URL with only a scheme, a host, and maybe a port, such as https://s3.eu-central-1.amazonaws.com"
      elsif uri.scheme != "https" && !(uri.scheme == "http" && Settings.loopback?(host))
        "#{field}.endpoint must be https: browsers send files and keys sign requests to it (plain http only to localhost)"
      end
    end

    # :nodoc:
    def self.loopback?(host : String) : Bool
      host.in?("localhost", "127.0.0.1", "[::1]", "::1")
    end

    # The bucket, with S3 storage.
    # :nodoc:
    def s3_bucket : S3::Bucket
      endpoint = @endpoint.presence.try { |text| URI.parse(text) } || URI.parse("https://s3.#{@region}.amazonaws.com")
      S3::Bucket.new(@bucket.to_s, @region, endpoint, @path_style)
    end

    # :nodoc:
    def s3_credentials : S3::SigV4::Credentials
      S3::SigV4::Credentials.new(@access_key_id.to_s, @secret_access_key.try(&.unwrap).to_s, nil)
    end
  end
end
