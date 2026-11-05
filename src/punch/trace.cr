require "./trace/ids"
require "./trace/span"
require "./trace/tracer"
require "./trace/console"

# Tracing: spans on the OpenTelemetry data model, one wide event per
# request, and exporters. Details in `docs/tracing.md`.
module Punch::Trace
end
