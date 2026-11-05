require "uri"

module Punch::OTLP
  # Where and how to export, from OpenTelemetry's standard variables, so a
  # collector's or vendor's instructions apply as written. Only OTLP over
  # HTTP with JSON is supported.
  #
  # | Variable | Default | |
  # |---|---|---|
  # | `OTEL_EXPORTER_OTLP_ENDPOINT` | none: no export | Base URL; `/v1/traces` and `/v1/metrics` are appended |
  # | `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `…_METRICS_ENDPOINT` | from the base | Full URL of one signal, used as it is |
  # | `OTEL_EXPORTER_OTLP_HEADERS` | none | `key=value,key2=value2`, values percent-encoded: API keys. Never shown |
  # | `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/json` | Anything else is refused |
  # | `OTEL_EXPORTER_OTLP_TIMEOUT` | `10000` | Milliseconds per request |
  # | `OTEL_SERVICE_NAME` | the binary's name | `service.name` |
  # | `OTEL_RESOURCE_ATTRIBUTES` | none | `key=value,…` added to the resource, such as `service.version=1.4.0` |
  # | `OTEL_METRIC_EXPORT_INTERVAL` | `60000` | Milliseconds between metric exports |
  # | `OTEL_SDK_DISABLED` | `false` | `true` exports nothing |
  struct Config
    VARIABLES = %w[OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
      OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_TIMEOUT OTEL_SERVICE_NAME
      OTEL_RESOURCE_ATTRIBUTES OTEL_METRIC_EXPORT_INTERVAL OTEL_SDK_DISABLED]

    # `nil`: that signal is not exported.
    getter traces : URI?
    getter metrics : URI?
    getter headers : Headers
    getter timeout : Time::Span
    getter metric_interval : Time::Span
    # `service.name`, the other resource attributes, and Punch's own.
    getter resource : Hash(String, String)

    def initialize(*, @traces : URI? = nil, @metrics : URI? = nil, @headers : Headers = Headers.new,
                   @timeout : Time::Span = 10.seconds, @metric_interval : Time::Span = 60.seconds,
                   @resource : Hash(String, String) = {} of String => String)
    end

    # The export settings in *env*, `nil` when nothing is exported, with
    # every problem added to *problems*. *environment* becomes
    # `deployment.environment.name`.
    def self.from(env, environment : String, problems : Array(String)) : Config?
      return if env["OTEL_SDK_DISABLED"]?.try(&.strip.downcase) == "true"

      protocol = env["OTEL_EXPORTER_OTLP_PROTOCOL"]?.presence
      if protocol && protocol != "http/json"
        problems << "OTEL_EXPORTER_OTLP_PROTOCOL: Punch exports http/json only, got #{protocol.inspect}"
      end
      base = env["OTEL_EXPORTER_OTLP_ENDPOINT"]?.presence.try { |text| url(text, "OTEL_EXPORTER_OTLP_ENDPOINT", problems) }
      traces = signal(env, "TRACES", base, "/v1/traces", problems)
      metrics = signal(env, "METRICS", base, "/v1/metrics", problems)
      headers = Headers.parse(env["OTEL_EXPORTER_OTLP_HEADERS"]?.presence, problems)
      timeout = milliseconds(env, "OTEL_EXPORTER_OTLP_TIMEOUT", 10_000, problems)
      interval = milliseconds(env, "OTEL_METRIC_EXPORT_INTERVAL", 60_000, problems)
      resource = resource(env, environment, problems)
      return unless traces || metrics

      # Headers carry the vendor's API key: never over plain HTTP to
      # another machine.
      unless headers.pairs.empty?
        [traces, metrics].compact.each do |uri|
          next if uri.scheme != "http" || uri.host.in?("localhost", "127.0.0.1", "::1", "[::1]")

          problems << "OTEL_EXPORTER_OTLP_HEADERS would go to #{uri.host} over plain http: use https, or a collector on this machine"
          break
        end
      end

      new(traces: traces, metrics: metrics, headers: headers, timeout: timeout, metric_interval: interval, resource: resource)
    end

    private def self.signal(env, name : String, base : URI?, path : String, problems : Array(String)) : URI?
      key = "OTEL_EXPORTER_OTLP_#{name}_ENDPOINT"
      if text = env[key]?.presence
        return url(text, key, problems)
      end

      base.try { |uri| uri.dup.tap { |full| full.path = full.path.rstrip('/') + path } }
    end

    private def self.url(text : String, key : String, problems : Array(String)) : URI?
      uri = URI.parse(text) rescue nil
      if uri.nil? || !uri.scheme.in?("http", "https") || uri.host.presence.nil? || uri.user || uri.fragment
        problems << "#{key} must be an http or https URL, such as http://localhost:4318, got #{Text.shown_url(text)}"
        return
      end
      uri
    end

    private def self.milliseconds(env, key : String, default : Int32, problems : Array(String)) : Time::Span
      text = env[key]?.presence || return default.milliseconds
      value = text.to_i?
      return value.milliseconds if value && 1 <= value <= 3_600_000

      problems << "#{key} must be a number of milliseconds from 1 to 3600000, got #{text.inspect}"
      default.milliseconds
    end

    private def self.resource(env, environment : String, problems : Array(String)) : Hash(String, String)
      resource = {} of String => String
      pairs(env["OTEL_RESOURCE_ATTRIBUTES"]?.presence, "OTEL_RESOURCE_ATTRIBUTES", problems) { |key, value| resource[key] = value }
      resource["service.name"] = env["OTEL_SERVICE_NAME"]?.presence || resource["service.name"]? || File.basename(PROGRAM_NAME)
      resource["service.instance.id"] ||= UUID.random.to_s
      resource["deployment.environment.name"] ||= environment
      resource["telemetry.sdk.name"] = "punch"
      resource["telemetry.sdk.language"] = "crystal"
      resource["telemetry.sdk.version"] = Punch::VERSION
      resource
    end

    # `key=value` pairs separated by commas, values percent-decoded, as
    # OpenTelemetry's variables write them.
    protected def self.pairs(text : String?, key : String, problems : Array(String), & : String, String ->) : Nil
      return unless text

      text.split(',').each do |pair|
        next if pair.blank?
        name, separator, value = pair.partition('=')
        name = name.strip
        if separator.empty? || name.empty?
          # The pair may hold a secret: name the position, never the text.
          problems << "#{key}: every entry must be key=value"
          next
        end
        yield name, URI.decode(value.strip)
      end
    end
  end

  # Headers sent with every export, such as an API key. They print as
  # their names only.
  struct Headers
    getter pairs : Array({String, String})

    def initialize(@pairs : Array({String, String}) = [] of {String, String})
    end

    def self.parse(text : String?, problems : Array(String)) : Headers
      pairs = [] of {String, String}
      Config.pairs(text, "OTEL_EXPORTER_OTLP_HEADERS", problems) do |name, value|
        if name.matches?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/) && !value.includes?('\n') && !value.includes?('\r')
          pairs << {name, value}
        else
          problems << "OTEL_EXPORTER_OTLP_HEADERS: #{name.inspect} is not a valid header"
        end
      end
      new(pairs)
    end

    def names : Array(String)
      pairs.map(&.[0])
    end

    def to_s(io : IO) : Nil
      io << names.join(", ") << " (values redacted)"
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end
end
