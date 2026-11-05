module Punch::CLI::Commands
  # Prints the settings this process would start with, from the
  # environment (`Punch::AppConfig`), or every problem with them.
  class Config < Command
    command "config", "Show the settings from the environment (PUNCH_STORAGE, PUNCH_PORT, ...), checked as at boot"

    struct Result
      include Report

      def initialize(@config : Punch::AppConfig)
      end

      def to_text(io : IO) : Nil
        io.puts "environment      #{@config.environment}"
        io.puts "storage          #{@config.storage} (primary: #{@config.primary_database})"
        io.puts "host             #{@config.host}"
        io.puts "port             #{@config.port}"
        io.puts "public URL       #{@config.public_url}"
        io.puts "trusted proxies  #{@config.trusted_proxies.empty? ? "none" : @config.trusted_proxies.join(", ")}"
        io.puts "trusted origins  #{@config.trusted_origins.empty? ? "none" : @config.trusted_origins.join(", ")}"
        io.puts "shutdown         #{@config.drain_delay_seconds} s accepting after /up turns 503, then up to #{@config.shutdown_timeout_seconds} s for requests in progress"
        io.puts "migrate          #{@config.migrate? ? "on: pending migrations are applied at boot" : "off: boot refuses while migrations are pending"}"
        io.puts "threads          #{@config.threads}"
        io.puts "trace            #{@config.trace.to_s.downcase}, spans of #{@config.trace_sample_percent} % of traces when exported"
        if otlp = @config.otlp
          io.puts "otlp traces      #{otlp.traces || "not exported"}"
          io.puts "otlp metrics     #{otlp.metrics.try { |url| "#{url} every #{otlp.metric_interval.total_seconds.to_i} s" } || "not exported"}"
          io.puts "otlp headers     #{otlp.headers.pairs.empty? ? "none" : otlp.headers}"
          io.puts "otlp service     #{otlp.resource["service.name"]}"
        else
          io.puts "otlp             off (OTEL_EXPORTER_OTLP_ENDPOINT unset)"
        end
        io.puts "backup           #{backup_text}"
        io.puts "cache            #{@config.cache? ? "on" : "off"}, cache.db up to #{@config.cache_mb} MiB"
        io.puts "jobs             #{@config.jobs? ? "on" : "off"} in serve, #{@config.job_concurrency} at once on #{@config.job_threads} thread(s), queues: #{@config.job_queues.try(&.join(", ")) || "all"}, kept #{@config.job_retention_hours} h"
        io.puts "ops              #{@config.ops? ? "on: ops.db keeps #{@config.ops_sample_percent} % of successful job runs and events, #{@config.ops_retention_days} days; slow requests from #{@config.ops_slow_ms} ms" : "off"}"
        io.puts "idempotency      answers under a key kept #{@config.idempotency_retention_hours} h"
        io.puts "webhooks         finished deliveries kept #{@config.webhook_retention_days} days"
        io.puts "probes           #{probes_text}"
        DATABASES.each do |name|
          io.puts "limits #{name.ljust(9)} #{limits_text(Punch::Database.limits_for(name))}"
        end
      end

      # The databases `serve` opens, whose limits an app may change.
      DATABASES = %w[primary cache queue ops]

      private def limits_text(limits : Punch::Database::Limits) : String
        parts = [] of String
        limits.each { |name, value| parts << "#{name} #{value}" }
        parts.join(", ")
      end

      private def probes_text : String
        return "off: requests for scanners' paths reach the router" unless @config.probes?

        allow = @config.probe_allow.empty? ? "" : ", never banned: #{@config.probe_allow.join(", ")}"
        return "on, nobody banned#{allow}" if @config.probe_ban_after.zero?

        bans = @config.probe_bans.join(", ") { |span| Punch::RateLimits.span_text(span) }
        "on, #{@config.probe_ban_after} within #{@config.probe_window_minutes} min ban for #{bans}#{allow}"
      end

      private def backup_text : String
        backup = @config.backup
        exempt = backup.exempt.empty? ? "" : ", exempt: #{backup.exempt.join(", ")}"
        if url = backup.display_url
          "#{url}, Litestream: #{backup.litestream}, encryption: #{backup.encryption.to_s.downcase}#{exempt}"
        else
          "off (PUNCH_BACKUP_URL unset)#{exempt}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "environment", @config.environment
          json.field "storage", @config.storage
          json.field "primary_database", @config.primary_database
          json.field "host", @config.host
          json.field "port", @config.port
          json.field "public_url", @config.public_url
          json.field "trusted_proxies", @config.trusted_proxies
          json.field "trusted_origins", @config.trusted_origins
          json.field "drain_delay_seconds", @config.drain_delay_seconds
          json.field "shutdown_timeout_seconds", @config.shutdown_timeout_seconds
          json.field "migrate", @config.migrate?
          json.field "threads", @config.threads
          json.field "trace", @config.trace.to_s.downcase
          json.field "trace_sample_percent", @config.trace_sample_percent
          json.field "otlp" do
            if otlp = @config.otlp
              json.object do
                json.field "traces", otlp.traces.try(&.to_s)
                json.field "metrics", otlp.metrics.try(&.to_s)
                json.field "metric_interval_ms", otlp.metric_interval.total_milliseconds.to_i64
                json.field "timeout_ms", otlp.timeout.total_milliseconds.to_i64
                json.field "headers", otlp.headers.names
                json.field "resource", otlp.resource
              end
            else
              json.null
            end
          end
          json.field "backup" do
            json.object do
              json.field "url", @config.backup.display_url
              json.field "exempt", @config.backup.exempt
              json.field "encryption", @config.backup.encryption.to_s.downcase
              json.field "litestream", @config.backup.litestream
            end
          end
          json.field "cache", @config.cache?
          json.field "cache_mb", @config.cache_mb
          json.field "jobs", @config.jobs?
          json.field "job_threads", @config.job_threads
          json.field "job_concurrency", @config.job_concurrency
          json.field "job_queues", @config.job_queues
          json.field "job_retention_hours", @config.job_retention_hours
          json.field "ops", @config.ops?
          json.field "ops_sample_percent", @config.ops_sample_percent
          json.field "ops_retention_days", @config.ops_retention_days
          json.field "ops_slow_ms", @config.ops_slow_ms
          json.field "idempotency_retention_hours", @config.idempotency_retention_hours
          json.field "webhook_retention_days", @config.webhook_retention_days
          json.field "probes" do
            json.object do
              json.field "enabled", @config.probes?
              json.field "ban_after", @config.probe_ban_after
              json.field "window_minutes", @config.probe_window_minutes
              json.field "bans_seconds", @config.probe_bans.map(&.total_seconds.to_i64)
              json.field "allow", @config.probe_allow
            end
          end
          json.field "limits" do
            json.object do
              DATABASES.each do |name|
                json.field name do
                  json.object { Punch::Database.limits_for(name).each { |limit, value| json.field limit, value } }
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      case settings = Config.settings
      in Punch::AppConfig then Result.new(settings)
      in Failure          then settings
      end
    end

    # The settings, or the failure `invalid_config` naming every problem.
    # *require_env* for `serve` and `jobs` (`AppConfig.from`).
    def self.settings(*, require_env : Bool = false) : Punch::AppConfig | Failure
      case config = Punch::AppConfig.from(ENV, require_env: require_env)
      in Punch::AppConfig then config
      in Array(String)    then Failure.new("invalid_config", "The environment has invalid settings:\n  #{config.join("\n  ")}")
      end
    end
  end
end
