require "uri"

module Punch::Backup
  # Where the database files are replicated, from the environment.
  # Litestream does the replication; Punch writes its configuration,
  # supervises it, and measures how far the replica is behind.
  #
  # | Variable | Default | |
  # |---|---|---|
  # | `PUNCH_BACKUP_URL` | none: nothing replicated | `s3://bucket/path`, with Litestream's `?endpoint=…&region=…&forcePathStyle=true` for other providers, or `file:///path`. Each file goes to `<path>/<name>` |
  # | `PUNCH_BACKUP_EXEMPT` | none | Comma-separated files not replicated, such as `ops`; outside development and test, every other file must have a replica |
  # | `PUNCH_BACKUP_ENCRYPTION` | `check` | `check` asks the bucket for its default encryption; `provider` states the provider encrypts every object at rest, for providers that do not answer that request |
  # | `PUNCH_LITESTREAM` | `litestream` on `PATH` | The Litestream binary |
  #
  # S3 keys come from `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (or
  # Litestream's `LITESTREAM_` ones), which Litestream reads itself.
  struct Config
    VARIABLES = %w[PUNCH_BACKUP_URL PUNCH_BACKUP_EXEMPT PUNCH_BACKUP_ENCRYPTION PUNCH_LITESTREAM]

    # The files Punch replicates; `cache.db` can be rebuilt and is not.
    FILES = %w[primary queue ops]

    enum Encryption
      # Ask the bucket (`GetBucketEncryption`).
      Check
      # The operator states the provider encrypts at rest.
      Provider
    end

    # `nil`: nothing is replicated.
    getter url : URI?
    getter exempt : Array(String)
    getter encryption : Encryption
    getter litestream : String

    def initialize(*, @url : URI? = nil, @exempt : Array(String) = [] of String,
                   @encryption : Encryption = Encryption::Check, @litestream : String = "litestream")
    end

    # The backup settings in *env*, with every problem added to *problems*.
    def self.from(env, problems : Array(String)) : Config
      url = env["PUNCH_BACKUP_URL"]?.presence.try { |text| url(text, problems) }
      exempt = env["PUNCH_BACKUP_EXEMPT"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
      exempt.each do |name|
        problems << "PUNCH_BACKUP_EXEMPT: #{name.inspect} is not a replicated file (#{FILES.join(", ")})" unless FILES.includes?(name)
      end
      encryption = case text = env["PUNCH_BACKUP_ENCRYPTION"]?.presence
                   when nil, "check" then Encryption::Check
                   when "provider"   then Encryption::Provider
                   else                   problems << "PUNCH_BACKUP_ENCRYPTION must be check or provider, got #{Text.shown_url(text)}"; Encryption::Check
                   end
      litestream = env["PUNCH_LITESTREAM"]?.presence || "litestream"
      new(url: url, exempt: exempt.uniq, encryption: encryption, litestream: litestream)
    end

    private def self.url(text : String, problems : Array(String)) : URI?
      uri = URI.parse(text) rescue nil
      problem = case uri.try(&.scheme)
                when "s3"   then uri.try { |parsed| s3_problem(parsed, text) }
                when "file" then uri.try { |parsed| file_problem(parsed, text) }
                else             "PUNCH_BACKUP_URL must be an s3:// or file:// URL, got #{Text.shown_url(text)}"
                end
      return uri unless problem

      problems << problem
      nil
    end

    private def self.s3_problem(uri : URI, text : String) : String?
      # Not shown: it may hold a secret key.
      return "PUNCH_BACKUP_URL must not hold keys; set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY instead" if uri.user || uri.password

      "PUNCH_BACKUP_URL must name a bucket, such as s3://backups/invoices, got #{Text.shown_url(text)}" if uri.host.presence.nil? || uri.fragment
    end

    private def self.file_problem(uri : URI, text : String) : String?
      if uri.host.presence || !uri.path.starts_with?('/') || uri.query || uri.fragment
        "PUNCH_BACKUP_URL must be an absolute file URL, such as file:///var/backups/invoices, got #{Text.shown_url(text)}"
      end
    end

    # The files of *names* (the ones a process opens) that are replicated.
    def replicated(names : Enumerable(String)) : Array(String)
      return [] of String unless url

      names.select { |name| FILES.includes?(name) && !exempt.includes?(name) }
    end

    # The files of *names* that need a replica and lack one.
    def missing(names : Enumerable(String)) : Array(String)
      return [] of String if url

      names.select { |name| FILES.includes?(name) && !exempt.includes?(name) }
    end

    # The replica URL of the file *name*: the base URL with `/<name>`
    # appended to its path, keeping Litestream's query options.
    def replica_url(name : String) : String
      base = url || raise ArgumentError.new("no backup URL")
      uri = base.dup
      uri.path = "#{uri.path.rstrip('/')}/#{name}"
      uri.to_s
    end

    # The base URL to show: the query is kept (endpoint, region), it
    # carries no secrets, which `from` refuses in the URL itself.
    def display_url : String?
      url.try(&.to_s)
    end

    # Whether the replica is an S3 bucket (`false` for a file replica).
    def s3? : Bool
      url.try(&.scheme) == "s3"
    end
  end
end
