require "json"

module Punch::OTLP
  # OTLP's JSON encoding (the protobuf JSON mapping): lowerCamelCase
  # fields, trace and span IDs as hex, 64-bit integers and timestamps as
  # decimal strings, enums as numbers.
  module Encode
    SCOPE = "punch"

    # Span kinds: INTERNAL 1, SERVER 2, CLIENT 3, CONSUMER 5.
    def self.kind(kind : Trace::Kind) : Int32
      case kind
      in .internal? then 1
      in .server?   then 2
      in .client?   then 3
      in .consumer? then 5
      end
    end

    def self.traces(io : IO, resource : Hash(String, String), traces : Array(Trace::Finished)) : Nil
      JSON.build(io) do |json|
        json.object do
          json.field "resourceSpans" do
            json.array do
              json.object do
                resource(json, resource)
                json.field "scopeSpans" do
                  json.array do
                    json.object do
                      scope(json)
                      json.field("spans") { json.array { traces.each { |trace| spans(json, trace) } } }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def self.spans(json : JSON::Builder, trace : Trace::Finished) : Nil
      # Exceptions belong to the trace; each goes on the span that recorded
      # it last, the root when that span is not in the trace.
      raised = trace.root.exceptions.group_by(&.source)
      trace.each_span do |span|
        mine = raised.delete(span.name) || [] of Trace::Raised
        if span.root?
          raised.each_value { |rest| mine.concat(rest) }
        end
        span(json, span, mine)
      end
    end

    private def self.span(json : JSON::Builder, span : Trace::Span, raised : Array(Trace::Raised)) : Nil
      duration = span.duration || return
      trace_id = span.trace_id || return
      span_id = span.span_id || return
      start = span.start_time
      finish = start + duration
      json.object do
        json.field "traceId", trace_id.to_s
        json.field "spanId", span_id.to_s
        span.parent_id.try { |parent| json.field "parentSpanId", parent.to_s }
        json.field "name", span.name
        json.field "kind", kind(span.kind)
        json.field "startTimeUnixNano", nanos(start)
        json.field "endTimeUnixNano", nanos(finish)
        json.field("attributes") { attributes(json) { |yield_pair| span.each_attribute { |key, value| yield_pair.call(key, value) } } }
        unless raised.empty?
          json.field "events" do
            json.array do
              raised.each do |entry|
                json.object do
                  json.field "timeUnixNano", nanos(finish)
                  json.field "name", "exception"
                  json.field "attributes" do
                    json.array do
                      attribute(json, "exception.type", entry.exception.class.name)
                      entry.exception.message.try { |message| attribute(json, "exception.message", message) }
                      attribute(json, "exception.stacktrace", entry.exception.backtrace?.try(&.join('\n')) || "")
                      attribute(json, "punch.source", entry.source)
                    end
                  end
                end
              end
            end
          end
        end
        json.field "status" do
          json.object do
            json.field "code", span.status.ok? ? 1 : span.status.error? ? 2 : 0
            span.status_message.try { |message| json.field "message", message } if span.status.error?
          end
        end
      end
    end

    def self.metrics(io : IO, resource : Hash(String, String), series : Array(Metrics::Series)) : Nil
      JSON.build(io) do |json|
        json.object do
          json.field "resourceMetrics" do
            json.array do
              json.object do
                resource(json, resource)
                json.field "scopeMetrics" do
                  json.array do
                    json.object do
                      scope(json)
                      json.field("metrics") { json.array { series.each { |one| metric(json, one) } } }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    private def self.metric(json : JSON::Builder, series : Metrics::Series) : Nil
      json.object do
        json.field "name", series.name
        json.field "description", series.description
        json.field "unit", series.unit

        case series.kind
        in .gauge?
          json.field("gauge") { json.object { points(json, series, start: false) } }
        in .counter?
          json.field "sum" do
            json.object do
              points(json, series, start: true)
              json.field "aggregationTemporality", 2 # cumulative
              json.field "isMonotonic", true
            end
          end
        in .histogram?
          json.field "histogram" do
            json.object do
              points(json, series, start: true)
              json.field "aggregationTemporality", 2
            end
          end
        end
      end
    end

    private def self.points(json : JSON::Builder, series : Metrics::Series, start : Bool) : Nil
      json.field "dataPoints" do
        json.array do
          series.points.each do |point|
            json.object do
              json.field("attributes") { attributes(json) { |pair| point.attributes.each { |key, value| pair.call(key, value) } } }
              json.field "startTimeUnixNano", nanos(series.start) if start
              json.field "timeUnixNano", nanos(series.time)

              case value = point.value
              in Int64   then json.field "asInt", value.to_s
              in Float64 then json.field("asDouble") { double(json, value) }
              in Metrics::Distribution
                json.field "count", value.count.to_s
                json.field("sum") { double(json, value.sum) }
                json.field("bucketCounts") { json.array { value.counts.each { |count| json.string(count.to_s) } } }
                json.field("explicitBounds") { json.array { value.bounds.each { |bound| json.number(bound) } } }
                if value.count > 0
                  json.field("min") { double(json, value.min) }
                  json.field("max") { double(json, value.max) }
                end
              end
            end
          end
        end
      end
    end

    private def self.resource(json : JSON::Builder, resource : Hash(String, String)) : Nil
      json.field "resource" do
        json.object do
          json.field("attributes") { json.array { resource.each { |key, value| attribute(json, key, value) } } }
        end
      end
    end

    private def self.scope(json : JSON::Builder) : Nil
      json.field "scope" do
        json.object do
          json.field "name", SCOPE
          json.field "version", Punch::VERSION
        end
      end
    end

    # The attributes the block passes on, as an array of key-value pairs.
    private def self.attributes(json : JSON::Builder, & : Proc(String, Trace::Value | Metrics::Value, Nil) ->) : Nil
      json.array do
        yield ->(key : String, value : Trace::Value | Metrics::Value) { attribute(json, key, value); nil }
      end
    end

    private def self.attribute(json : JSON::Builder, key : String, value : Trace::Value | Metrics::Value) : Nil
      json.object do
        json.field "key", key
        json.field("value") { any(json, value) }
      end
    end

    private def self.any(json : JSON::Builder, value : Trace::Value | Metrics::Value) : Nil
      json.object do
        case value
        in String  then json.field "stringValue", value
        in Bool    then json.field "boolValue", value
        in Int64   then json.field "intValue", value.to_s
        in Float64 then json.field("doubleValue") { double(json, value) }
        in Array(String)
          json.field "arrayValue" do
            json.object { json.field("values") { json.array { value.each { |item| any(json, item) } } } }
          end
        end
      end
    end

    # Non-finite numbers as the protobuf JSON mapping writes them.
    private def self.double(json : JSON::Builder, value : Float64) : Nil
      if value.nan?
        json.string("NaN")
      elsif value.infinite?
        json.string(value > 0 ? "Infinity" : "-Infinity")
      else
        json.number(value)
      end
    end

    private def self.nanos(time : Time) : String
      (time.to_unix.to_i128 * 1_000_000_000 + time.nanosecond).to_s
    end
  end
end
