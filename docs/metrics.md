# Metrics

Learn it in: [Tracing and Metrics](guides/tracing-and-metrics.md).

Traces say what one request did (`docs/tracing.md`); metrics say how the process is doing between requests. Punch's own are the SQLite signals of each database's writer. They are on the OpenTelemetry data model, so an exporter can send them as they are.

## What Punch measures

| Metric | Kind | Unit | Attributes | Means |
|---|---|---|---|---|
| `db.client.connection.pending_requests` | gauge | `{request}` | `db.namespace`, `db.client.connection.pool.name` (`primary writer`) | writes waiting for the writer, from `write` until the writer takes them, including those blocked on a full queue (`queue_size`) |
| `punch.db.size` | gauge | `By` | `db.namespace` | size of the database file, without its WAL |
| `punch.db.wal.size` | gauge | `By` | `db.namespace` | size of the `-wal` file. It shrinks only to `journal_size_limit` (64 MB) after a checkpoint |
| `punch.db.wal.frames` | gauge | `{frame}` | `db.namespace` | frames in the WAL not yet copied into the database file, as of the last commit or checkpoint |
| `punch.db.checkpoint.duration` | histogram | `s` | `db.namespace`, `punch.db.checkpoint.complete` | each checkpoint the writer ran; `complete: false` when a reader still needed older pages, so frames stayed behind |
| `punch.backup.lag` | gauge | `s` | `db.namespace` | how long the oldest change not yet in the replica has waited; 0 when the replica has everything (`docs/backup.md`) |
| `punch.backup.verification.age` | gauge | `s` | | time since the restore check last passed; before the first, since the process started (`docs/backup.md`, "The restore check") |
| `punch.backup.recovery` | gauge | `1` | | 1 while a restore waits for confirmation and the process's job workers, outbox relay, and schedules are stopped (`docs/backup.md`, "Restoring") |
| `punch.backup.sidecar.restarts` | counter | `{restart}` | | times Litestream exited unasked and this process started it again |
| `punch.http.probes` | counter | `{request}` | | requests for paths only scanners ask for, answered 404 without a trace (`docs/http.md`, "Probes and bans") |
| `punch.http.refused` | counter | `{request}` | | requests from banned addresses, answered 403 without a trace |
| `punch.http.bans` | counter | `{ban}` | | addresses this process banned |
| `punch.http.banned` | gauge | `{address}` | | addresses banned now, by any process sharing `cache.db` as of the last read |

The writer queue uses the name OpenTelemetry's database conventions give pending requests on a connection pool; the others have no convention and carry `punch.`. A database in memory reports only the queue. A closed database reports nothing.

**Checkpoints.** The writer checkpoints itself instead of leaving it to SQLite's automatic checkpoint: after a transaction leaves `checkpoint_pages` (1,000, SQLite's own threshold) frames in the WAL, it runs a passive checkpoint and times it. It does so after handing that write its answer, so the request whose commit crossed the threshold does not wait for it; the next write does, and its `punch.db.writer_wait_ms` shows it. A passive checkpoint never waits for readers: it copies what no reader still needs. After one that left frames behind, the next runs only once `checkpoint_pages` more frames have been written, not after every write: Litestream holds a read transaction between its own checkpoints (`docs/backup.md`), and would otherwise make every write pay for a checkpoint that copies nothing. Checkpoints that stay incomplete while `punch.db.wal.frames` and `punch.db.wal.size` keep growing mean read transactions that last too long.

What to watch:

- `pending_requests` above a few for long means writes arrive faster than one writer commits them: long write transactions, or slow ones (look at the wide events' `punch.db.writer_wait_ms` and `punch.db.duration_ms`).
- Checkpoint durations of tens of milliseconds and more stall every write behind them: slow disk, or a WAL that grew large before it could be checkpointed.

## Collecting

`serve` and `jobs` register every database they open with the process's registry, `Punch::Metrics.registry`. Nothing is computed until someone collects: the writer keeps two counters and one histogram per database, and the rest is read when collected.

```crystal
registry = Punch::Metrics::Registry.new
databases.observe(registry)              # or database.observe(registry); the default is Punch::Metrics.registry
registry.collect                         # => Array(Punch::Metrics::Series): name, kind, unit, points
```

An app can add its own observed instrument:

```crystal
Punch::Metrics.registry.observe("app.imports.pending", :gauge, "{file}", "Files waiting for import") do |recorder|
  recorder.record(Imports.pending, Punch::Metrics::Attributes{"source" => "sftp"})
end
```

Names are lower case with dots, as in OpenTelemetry. Registering a name again adds another callback to the same instrument (one per database for Punch's); another kind or unit for it raises. A callback that raises is logged, and the others are still collected. `Punch::Metrics::Histogram` records durations (`DURATION_BOUNDS`, in seconds) from any thread for a `:histogram` callback to report with `histogram.snapshot`.

Counters and histograms are cumulative from when the instrument was registered; `Series#start` says when.

## Exporting

With `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`) set, `serve` and `jobs` send every instrument of `Punch::Metrics.registry` over OTLP/HTTP with JSON every `OTEL_METRIC_EXPORT_INTERVAL` (60 s), and once more at shutdown, before the databases close. Settings and headers as for traces (`docs/tracing.md`, "Exporting over OTLP"). Gauges are sent as gauges; counters as cumulative monotonic sums and histograms as cumulative histograms, both from `Series#start`, so an export that is lost loses resolution, not counts. A failed export is retried within the interval and then given up; the next one carries the totals.

```crystal
exporter = Punch::OTLP::MetricExporter.new(config)   # Punch::Metrics.registry by default
exporter.start                                       # and exporter.stop at shutdown
```

Without an endpoint, nothing collects them; `punch db PATH` shows a file's WAL size from outside the process. The exporter adds `punch.otlp.spans` (`docs/tracing.md`).

## Testing

```crystal
registry = Punch::Metrics::Registry.new
db.observe(registry)
metrics = Punch::Spec.metrics(registry)
metrics.value("punch.db.wal.frames", "db.namespace": "primary").should be > 0
metrics.distribution("punch.db.checkpoint.duration", "punch.db.checkpoint.complete": true).count.should eq(1)
metrics.has?("punch.db.checkpoint.duration").should be_false
```

`value` and `distribution` fail the example unless exactly one point of that name has at least those attributes. A smaller `checkpoint_pages` in the database's `Config` makes checkpoints happen in a spec; they run after the write returns, so wait with `Punch::Spec.eventually`.
