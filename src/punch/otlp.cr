require "uuid"
require "./trace"
require "./metrics"
require "./otlp/config"
require "./otlp/encode"
require "./otlp/sender"
require "./otlp/exporters"

# Export of traces and metrics over OTLP/HTTP with JSON, to an OpenTelemetry
# collector or a vendor's endpoint. Details in `docs/metrics.md` and
# `docs/tracing.md`.
module Punch::OTLP
end
