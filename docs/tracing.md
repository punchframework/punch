# Tracing and wide events

Learn it in: [Tracing and Metrics](guides/tracing-and-metrics.md).

Every request is a trace: a root span that is also the request's **wide event**, with child spans for the work done inside it. Telemetry is on by default; turning it off is the opt-in.

## What a request records

| Span | Kind | Attributes |
|---|---|---|
| `GET /billing/invoices/:invoice_id` (the root, the wide event) | server | `http.request.method`, `url.path`, `url.scheme`, `client.address`, `user_agent.original`, `http.route`, `http.response.status_code`, `http.response.body.size`, `punch.request_id`, `punch.operation`, `punch.outcome`, `punch.input.errors`, and the totals below |
| `input` | internal | parsing the input |
| `primary read`, `primary write` | internal | `db.namespace`; on a write, `punch.db.writer_wait_ms` |
| one per SQL statement, named by the query (`Billing::Queries.invoice_by_id`) or its first keyword (`SELECT`) | client | `db.system.name`, `db.namespace`, `db.operation.name`, `db.query.text`, `punch.query`, `db.response.returned_rows` or `punch.db.changes` |

Names follow OpenTelemetry's semantic conventions where one exists; Punch's own start with `punch.`. Until a route matches, the root is named by the method alone (`GET`). `GET /up` is not traced.

**Totals on the wide event**, added by every statement whether its span is recorded or not: `punch.db.queries`, `punch.db.rows`, `punch.db.changes`, `punch.db.errors`, `punch.db.duration_ms`, `punch.db.writer_wait_ms`.

`punch.outcome` is the result type's name in snake_case (`sent`, `not_found`), or `invalid_input` for a rejection. A response from 500 on, or an exception, marks the root as failed; the wide event then carries `error`, and with an exception `exception.type` and `exception.message`.

**Never recorded:** SQL arguments, request and response bodies, query strings, headers other than `User-Agent`. An exception's message is recorded as it is, and may quote input (SQLite's FTS5 errors quote the search text, for one): it reaches stdout, `ops.db`, and OTLP alike. A `Punch::Secret` cannot be an attribute: `span["key"] = secret` does not compile.

## Adding fields and spans

```crystal
def call(input : Input, db : Punch::Writer) : Result
  Punch::Trace.event["invoice.id"] = input.invoice_id.to_s   # a field of the wide event

  Punch::Trace.span("charge card", :client) do |span|        # a child span
    span["payment.provider"] = "stripe"
    gateway.charge(amount)
  end
end
```

- Values are `String`, `Bool`, integers, floats, or `Array(String)`. Convert domain types where you set them.
- Prefix business fields with the app's own namespace (`invoice.id`, `customer.plan`).
- `Punch::Trace.span` records an exception, finishes the span, and raises again.
- `Punch::Trace.event` is the wide event wherever the code runs in the request or job, also inside a transaction of a trace that is not sampled, where the current span does not record.
- An exception the code handles itself, but that someone should see, goes on the trace with `Punch::Trace.event.record_exception(ex, "where")`: it does not fail the span, and the ops console lists it (`docs/ops.md`). `span.error(ex)` records too. The same exception is kept once per trace, under the name of the last span that recorded it: the request or job it reached, or the subscriber that swallowed it.
- The current span is **fiber-scoped**, like `Log.context`, never thread-local. A fiber you spawn starts without one: pass the span along and use `Punch::Trace.with(span) { … }`. Inside `db.write { … }` the transaction span is current, although the block runs on the writer's thread.

## Tracers, exporters, sinks

```crystal
tracer = Punch::Trace::Tracer.new(
  exporters: [Punch::Trace::ConsoleExporter.new] of Punch::Trace::Exporter,  # spans, for development
  events: [Punch::Trace::JSONEvents.new] of Punch::Trace::EventSink,        # wide events (the default)
  sample_ratio: 1.0)
server = Punch::HTTP::Server.new(config, tracer) { |context| router.call(context) }
```

| Piece | Does |
|---|---|
| `JSONEvents` (default) | One JSON line per wide event on stdout: `time`, `name`, `trace_id`, `span_id`, `duration_ms`, `error`, then the attributes. A writer fiber writes and flushes in batches; `close` (called by the server's shutdown) writes what is left |
| `LogEvents` | The wide event as a `punch.request` log entry, fields under the metadata key `event`. For apps that send everything through `Log`; slower (below) |
| `ConsoleExporter` | Each sampled trace as an indented tree on stderr, for development |
| `Punch::Ops::Sink` | Errors, job runs, and committed events into `ops.db`, for the ops console (`docs/ops.md`); added by `serve` and `jobs` unless `PUNCH_OPS=off` |
| `MemoryExporter`, `MemoryEvents` | Keep traces or events in memory: specs, and later the ops console's trace view |
| `Tracer.off` | No spans, no events, no request log |

Child spans are recorded only when the trace is **sampled**: with at least one exporter, by `sample_ratio` decided on the trace ID, or by a sampled `traceparent` from a trusted proxy. Without an exporter, only the root is recorded, for the wide event. A trace records at most 1,024 spans; the rest are counted in `punch.trace.dropped_spans`.

**Trace context.** A well-formed W3C `traceparent` header from a trusted proxy (`docs/http.md`) continues that trace; from anyone else it is ignored, as `X-Request-ID` is. Without a forwarded request ID, the request ID is the trace ID, so the ID a client sees in a problem response finds the wide event.

**Errors outside a trace**, such as a failing heartbeat in a worker's loop, are reported with `tracer.report(ex, "jobs: heartbeat")`: a failed trace of its own, so every sink sees it.

**Committed events** are named on the wide event in `punch.events` (at most 100) when their transaction commits; `punch.events.published` counts every publish, also of Commands that fail.

## Exporting over OTLP

Set OpenTelemetry's own variables, and `serve` and `jobs` send sampled traces to an OpenTelemetry collector or a vendor's OTLP endpoint, over HTTP with JSON (no protobuf, no gRPC):

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.com    # /v1/traces and /v1/metrics are appended
OTEL_EXPORTER_OTLP_HEADERS="x-api-key=…"                 # values percent-encoded; never shown
OTEL_RESOURCE_ATTRIBUTES="service.version=1.4.0"         # OTEL_SERVICE_NAME defaults to the binary's name
PUNCH_TRACE_SAMPLE_PERCENT=10                             # spans of 10 % of traces (default 100)
```

| Variable | Default | |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | none: nothing exported | base URL |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `…_METRICS_ENDPOINT` | the base plus `/v1/traces`, `/v1/metrics` | one signal's full URL |
| `OTEL_EXPORTER_OTLP_HEADERS` | none | `key=value,…`: API keys |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/json` | anything else stops the boot |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | `10000` ms | per request |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | the binary's name | the resource; Punch adds `service.instance.id`, `deployment.environment.name` (`PUNCH_ENV`), and `telemetry.sdk.*` |
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` ms | `docs/metrics.md` |
| `OTEL_SDK_DISABLED` | `false` | `true` exports nothing |
| `PUNCH_TRACE_SAMPLE_PERCENT` | `100` | share of traces whose spans are recorded and exported, by trace ID; a sampled `traceparent` from a trusted proxy wins |

`punch config` (`bin/<app> config`) shows the URLs, the header names, and the service name; every malformed value stops the boot with the others, and a problem with the headers never echoes their text.

**What is sent:** every span of each sampled trace, with its attributes, status (an error's message is the exception's type or the short reason, as on the wide event), and the trace's exceptions as `exception` events with type, message, and stack trace, on the span that recorded them last. Wide events still go to stdout as before (`PUNCH_TRACE`), for every request, sampled or not; with the default 100 % every wide event also reaches the receiver as the root span of its trace.

**Never in the way of a request:** `export` only queues the finished trace. One fiber sends a batch once it holds 512 spans or its first trace has waited 5 seconds. When 2,048 traces are queued, further ones are dropped. A receiver answering 429, 502, 503, or 504, or not answering, is asked again with growing pauses (honouring `Retry-After`) for up to 30 seconds; other answers drop the batch. Drops are counted in the metric `punch.otlp.spans` (`punch.otlp.outcome`: `exported` or `dropped`) and logged at most once a minute on `punch.otlp`. At shutdown, the tracer's `close` sends what is queued, within the timeout.

**Cost:** an exporter makes the tracer record child spans of sampled traces (the table below: about 10 % of the throughput at saturation with every trace sampled). Encoding costs about 2 µs and 450 bytes per span in a release build, in the exporter's fiber. Under heavy load, sample.

In code:

```crystal
config = Punch::OTLP::Config.new(traces: URI.parse("http://localhost:4318/v1/traces"))
tracer = Punch::Trace::Tracer.new(exporters: [Punch::OTLP::TraceExporter.new(config)] of Punch::Trace::Exporter, sample_ratio: 0.1)
```

## Testing

```crystal
trace = Punch::Spec.trace do
  db.read { |reader| Billing::Invoices::Table.find(reader, id) }
end
trace.should have_span("Billing::Invoices::Table.find", "db.response.returned_rows": 1)
trace.root["punch.db.queries"].should eq(1)
trace["primary read"].status.error?.should be_false
```

`Punch::Spec.trace` runs the block in the root of a fully recorded trace and returns it. `have_span(name, **attributes)` matches a span by name and at least those attributes. For effects after a response, such as the wide event of a served request, `Punch::Spec.eventually { … }` retries until the expectation holds. Endpoint specs record every span of each request and return it with the response: `response.trace` (`docs/testing.md`).

## Cost

Measured with `wrk`, 4 threads and 64 connections against a 4-thread server on the same 8-core machine, a Query reading 20 rows from a file database, release build:

| Telemetry | Requests/s | p50 | p99 |
|---|---|---|---|
| `Tracer.off` | 111,000 | 0.52 ms | 1.9 ms |
| root span only, no sink | 98,000 | 0.59 ms | 2.2 ms |
| default: wide events as JSON lines | 93,000 | 0.62 ms | 2.2 ms |
| every span recorded and exported to memory | 83,000 | 0.70 ms | 2.8 ms |
| wide events through `Log` (`LogEvents`) | 72,000 | 0.83 ms | 3.3 ms |

The machine was saturated, so each extra microsecond shows; a server with idle CPU pays it as latency only. Writing a wide event costs about 0.9 µs, written by hand because `JSON::Builder` took 2 µs.
