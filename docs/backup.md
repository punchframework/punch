# Backup

Learn it in: [Backup and Restore](guides/backup-and-restore.md).

Every database file except the cache is replicated to S3-compatible storage with [Litestream](https://litestream.io) 0.5: `primary.db`, `queue.db`, and `ops.db`, each to its own path. `cache.db` can be rebuilt and is not replicated. Punch writes Litestream's configuration, runs Litestream next to the app with only its own and the bucket's variables (`AWS_*`, `LITESTREAM_*`, `PATH`, `HOME`, `TZ`, `TMPDIR`, `SSL_CERT_*`; never the master key or the app's credentials), restarts it when it exits, measures how far each replica is behind, and checks that the bucket encrypts what it stores. Every night a restore check restores the backup next to the live files, checks it, and runs the reconciliation of a restore as a dry run. `punch restore` restores for real and puts the app into recovery mode until someone confirms the reconciliation.

## Turning it on

```sh
PUNCH_BACKUP_URL="s3://backups/invoicing"   # each file goes to backups/invoicing/<name>
AWS_ACCESS_KEY_ID=...                        # read by Litestream and by Punch's encryption check
AWS_SECRET_ACCESS_KEY=...
PUNCH_ENV=production bin/invoicing serve
```

| Variable | Default | |
|---|---|---|
| `PUNCH_BACKUP_URL` | none: nothing replicated | `s3://bucket/path`, or `file:///path` for a directory. Other providers take Litestream's options in the query: `s3://backups/app?endpoint=https://<account>.r2.cloudflarestorage.com&region=auto`. The URL must not hold keys |
| `PUNCH_BACKUP_EXEMPT` | none | Comma-separated files not replicated: `ops` to save the uploads of a write-heavy `ops.db` |
| `PUNCH_BACKUP_ENCRYPTION` | `check` | `check` asks the bucket for its default encryption; `provider` states that the provider encrypts every object at rest, for providers that do not answer that request |
| `PUNCH_LITESTREAM` | `litestream` on `PATH` | The Litestream binary |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION` | | S3 credentials and default region, as every S3 tool reads them (Litestream also takes `LITESTREAM_ACCESS_KEY_ID` and `LITESTREAM_SECRET_ACCESS_KEY`). Never printed |

Replication is off in development and test unless `PUNCH_BACKUP_URL` is set. **Everywhere else, a file without a replica fails the health check** (`/up` answers 503, naming the files) until `PUNCH_BACKUP_URL` is set or the file is listed in `PUNCH_BACKUP_EXEMPT`. A deploy without backup configuration therefore does not go live unnoticed.

When files are to be replicated and Litestream cannot run (the binary is missing, or the storage directory's path is too long for its control socket), `serve` and `jobs` refuse to start.

## The sidecar

`serve` and `jobs` each start a `Punch::Backup::Sidecar`, which runs `litestream replicate` with a configuration Punch writes to `$PUNCH_STORAGE/litestream.yml` at every start (`punch backup:config` prints it):

```yaml
# Written by Punch from PUNCH_BACKUP_URL at every start (docs/backup.md). Do not edit.
socket:
  enabled: true
  path: "/var/lib/invoicing/litestream.sock"
logging:
  level: info
  type: json
  stderr: true
dbs:
  - path: "/var/lib/invoicing/primary.db"
    replica:
      url: "s3://backups/invoicing/primary"
  ...
```

Litestream's defaults apply otherwise: a sync every second, a snapshot a day, its own checkpoints. Its logs are JSON lines on stderr, next to the app's.

- **One Litestream per storage directory.** Two Litestreams writing the same replica corrupt it, and several processes open the same files: `serve` and `jobs`, and the old and new process during a deploy. A sidecar runs Litestream only while it holds an exclusive lock on `litestream.lock`; the others try every 5 seconds. When the process holding it stops, another takes over within that time. Litestream inherits the locked file, so if the app process is killed with SIGKILL, the orphaned Litestream keeps the lock and keeps replicating, and no second one starts beside it.
- **Restarted when it exits.** After 1 s, doubling up to 60 s while it keeps failing. Each exit is a `Punch::Backup::SidecarExited` error in the ops console, and a warning in the log. `punch.backup.sidecar.restarts` counts them.
- **Stopped last.** At shutdown the sidecar runs after the databases close: it sends SIGTERM, Litestream syncs what is left (up to 30 s), and the process exits. Nothing is lost when Litestream is killed or stops early either: a restarted Litestream replicates the files as it finds them, so a write made while it was down only reaches the replica later.

Under systemd, use `KillMode=mixed`, so SIGTERM reaches the app only and the app stops Litestream after its last writes; with the default, both get SIGTERM at once and writes during the drain reach the replica with the next start. The systemd recipe of `punch new` sets it.

**Litestream adds two tables** to every file it replicates, `_litestream_seq` and `_litestream_lock`. `punch db:migrate` leaves them out of `db/schema.sql`, and Punch's own files (`queue.db`, `ops.db`) accept them. So does Punch's `_punch_heartbeat` (next section).

## Heartbeat

Litestream uploads a file only when its database changes. The replica of a quiet file therefore ends at its last write, and from the replica alone a quiet file cannot be told from one whose uploads stopped. So every process that replicates writes one row into `_punch_heartbeat` (one row: the time) of each replicated file that has not changed for 15 seconds, looking every 5 seconds; Litestream uploads it like any change. While Litestream runs, every replica then has a file at most about 20 seconds old, and a replica that ends more than 25 seconds before the newest one is behind. Busy files get no extra writes; a quiet one costs one upload every 15 to 20 seconds (about 5,000 a day per file, about $0.75 a month per quiet file at AWS S3's request price; `queue.db` is rarely quiet, since the workers' own heartbeat writes it every 10 seconds).

The table is created on the first beat, outside the app's migrations, and left out of `db/schema.sql` like Litestream's tables.

## Lag

`punch.backup.lag` (gauge, seconds, per `db.namespace`) is how long the oldest change not yet in the replica has waited: zero when nothing changed since Litestream's last successful upload, otherwise the time since that upload. Litestream exports no such metric; Punch reads `last_sync_at` from Litestream's control socket (`GET /list`, the time of the last successful upload) and compares it with the WAL file's modification time, so writes of every process count. Every process measures it every 15 seconds, whether its own sidecar runs Litestream or another process's does. Its resolution is about one sync interval (1 s).

While no Litestream answers, the lag grows from the last upload the process saw. A lag above five minutes is reported once as a `Punch::Backup::Lagging` error, until it recovers.

**The lag does not fail the health check.** A failing `/up` takes the app out of its proxy, and a storage outage should not take the app down with it. Missing configuration and an unencrypted bucket do fail it: those are mistakes to fix before going live.

## Encryption

Litestream 0.5 does not encrypt replicas (it removed its age encryption and points to the provider), so the bucket must encrypt at rest. With `PUNCH_BACKUP_ENCRYPTION=check`, each process asks the bucket once at start and every 6 hours (`GetBucketEncryption`, signed with AWS Signature Version 4; every 5 minutes while there is no answer):

| Answer | Health |
|---|---|
| A default encryption (`AES256`, `aws:kms`, ...) | ok |
| No default encryption | fails: turn it on |
| No answer: no keys, access denied (`s3:GetEncryptionConfiguration`), a provider without the request, unreachable | fails: grant the permission, or set `PUNCH_BACKUP_ENCRYPTION=provider` |

AWS has encrypted every new object since 2023 and answers `AES256` for every bucket. A provider that encrypts everything but answers the request with `NotImplemented` or not at all needs `PUNCH_BACKUP_ENCRYPTION=provider`: a statement by the operator, shown by `punch config` and `punch backup`. A `file://` replica is not checked. Sensitive columns are encrypted by the app itself, which a provider's encryption does not replace.

## The restore check

A backup that cannot be restored is not a backup. Every night at 04:00 UTC, `Punch::Backup::Verify` (a recurring job, at the lowest priority) restores every replicated file into a directory of its own in `PUNCH_STORAGE` and checks it; `punch backup:verify` runs the same check now. The check:

1. **Plans** each file's restore to its latest point (`litestream restore -dry-run`, which downloads nothing).
2. **Aligns** when a replica is behind: if the earliest replica ends more than 25 seconds before the newest (longer than a heartbeat allows), every file is restored to the end of the earliest, as `punch restore` will do, so the files agree. Otherwise each file is restored to its latest: quiet files are not behind, and aligning to them would throw away the newest writes of the others.
3. **Restores** each file to the last transaction of its plan (`-txid`), so what is checked is what was planned, and runs `PRAGMA integrity_check` on it.
4. **Reconciles** the restored `primary.db` and `queue.db` as a dry run: what `punch restore` would propose after a restore of these files. Nothing is changed.
5. **Removes** the copies and keeps the result in `PUNCH_STORAGE/verification.json`.

| Reconciliation list | What | Proposed by `punch restore` |
|---|---|---|
| hand over again | outbox entries marked as handed over, with no job in the queue (the queue is older) | hand them over again |
| discard | unfinished jobs from an outbox entry the primary does not have (the queue is newer) | discard |
| ran for a Command not in the primary | finished jobs from such entries: what they did outside cannot be taken back | nothing; for review |
| run again | jobs that finished at the primary's point or after it, or within 5 seconds before it: their writes may be gone | run again |
| interrupted | jobs running at the queue's point | ready again, as after a crash |

Only entries and jobs within the job retention window (`PUNCH_JOB_RETENTION_HOURS`) are compared, since older ones may be purged on one side. A job enqueued without the outbox (by another job or a schedule) cannot be matched to a Command; it shows only as run again or interrupted. While the app runs, the files are replicated within a second or two of each other, so the dry run usually finds nothing, or a few jobs that finished in the last seconds.

**Results.** The job's wide event carries `punch.backup.verify.*` (passed, files, bytes, each file's transaction and seconds) and `punch.backup.reconcile.*` (the count of each list and the findings), shown with the run in the ops console. A failed check (a replica that cannot be restored, a damaged file, a reconciliation that cannot read the files) is a `Punch::Backup::VerificationFailed` error. `punch backup` shows the last result, and `punch.backup.verification.age` (gauge, seconds) is the time since a check last passed: alert on it above about two days, which catches a failing check and one that does not run. **The check does not fail the health check,** for the same reason as the lag.

**Space.** The copies need as much space as the live files. The check refuses to start when they would leave less than 1 GB or a tenth of the filesystem free, whichever is more, since the live files must still be able to grow; that is a failed check. Restoring from S3 downloads the replicas every night: with large databases, mind the provider's transfer costs.

## Restoring

```sh
bin/invoicing restore --dry-run              # what would be restored; downloads nothing
bin/invoicing restore                        # every replicated file to its latest point
bin/invoicing restore --at 2026-10-14T09:30:00Z   # or to a time before something went wrong
bin/invoicing recovery                       # the reconciliation, while in recovery mode
bin/invoicing recovery:confirm               # apply it; background work starts
```

`punch restore` reads the replica from `PUNCH_BACKUP_URL` and restores into `PUNCH_STORAGE`, on the machine that runs the app (an empty storage directory on a new machine works too). It:

1. **Refuses while the app runs.** `serve` and `jobs` hold a shared lock on `PUNCH_STORAGE/punch.lock`; a restore needs it exclusively, and also `litestream.lock`, so it refuses while a Litestream left by a killed process still replicates (stop that one first). While a restore runs, `serve` and `jobs` refuse to start.
2. **Restores into a scratch directory** in the storage directory, as the restore check does: each file planned to its latest point (with `--at`, to its last point at that second or before), every file aligned to the earliest replica's end when that one is behind, each checked with `PRAGMA integrity_check`. When any file cannot be restored intact, nothing is replaced.
3. **Reconciles** the restored `primary.db` and `queue.db` (the lists in the table above).
4. **Moves the replaced files aside** into `PUNCH_STORAGE/replaced-<time>-<random>/`: the replicated files with their WAL, Litestream's local state (`.<name>.db-litestream`), and `cache.db`, whose values were computed from the replaced data (durable rate limits start over). Nothing is deleted; remove the directory once the restore is confirmed good. Files exempted from replication stay.
5. **Moves the restored files in** and writes the report to `PUNCH_STORAGE/recovery.json`. If the restore stops between moving files out and in, `restore-incomplete.json` stays behind and `serve` and `jobs` refuse to start until `punch restore` runs again.

**Recovery mode.** While `recovery.json` exists, `serve` and `jobs` serve requests but start no job workers, no outbox relay, and no recurring schedules. Commands still write their outbox entries, which wait. `/up` stays healthy, so a restored app goes back into its proxy; the metric `punch.backup.recovery` is 1 while background work waits, `punch backup` shows it, and each process logs a warning at start.

**Confirming.** `punch recovery` shows the files, their points, and the reconciliation's lists with the jobs' IDs and types; so does the ops console at `/_punch/recovery`, linked from every console page's overview while recovery mode lasts. `punch recovery:confirm`, or the console's button, applies them while the app runs:

| List | Confirming |
|---|---|
| hand over again | the entries are marked pending; the relay hands them over (a key the queue has is ignored) |
| discard | the jobs are discarded, with the reason in their error |
| ran for a Command not in the primary | nothing: check what they did outside the app (a mail sent, a charge made) |
| run again | the jobs are made ready with fresh attempts |
| interrupted | the jobs are made ready, the interrupted attempt not counted |

Only jobs and entries still in the state the report saw change, so a job retried or discarded by hand meanwhile is left alone. Process rows of the restored queue are removed. The report moves to `recovered.json`, and every running process starts its background work within 2 seconds.

**Replication goes on in the same replica.** When Litestream starts on a restored file, it notices that the file is behind its replica and continues the replica from it ("detected database behind replica"): a later restore of the latest point has the writes made after the restore, not those the restore went back from (checked with Litestream 0.5.17, file replica and S3 through versitygw). Restoring to a time before the restore still returns the old history.

**Uploaded files are not part of a restore.** They live in the upload bucket, which Litestream does not touch: keep its versioning or replication with the provider. A restored database may name files discarded since, and lack keys of files claimed since (`docs/uploads.md`).

## Who can write the bucket

A restore, and the nightly restore check, take whatever the bucket holds: they check that each file is a sound database (`PRAGMA integrity_check`), not who wrote it. Whoever can write the bucket can therefore put a database of their making into the next restore. Give the app keys that can add objects but not delete or overwrite old ones, turn on the bucket's versioning or object lock, and restore with keys that can only read. Punch's SQLite refuses `writable_schema` and calls only innocuous functions from a schema (`docs/persistence.md`), which keeps a crafted file from running more than SQL of its own.

## Command line

| Command | Does |
|---|---|
| `punch backup [--json]` | The replica, the files replicated, exempted, or lacking one; whether Litestream answers (version, process, uptime); each file's status, lag, and last upload; the bucket's encryption, asked now; the last restore check |
| `punch backup:verify [--json]` | The restore check, now: restores every file next to the live ones, checks it, runs the reconciliation as a dry run, and removes the copies. Fails (exit 1, the result in `details`) when the check does |
| `punch backup:config [--json]` | The Litestream configuration `serve` and `jobs` write, to run Litestream another way or read what it does |
| `punch restore [--at TIME] [--dry-run] [--json]` | Restores every replicated file into the storage directory and starts recovery mode (see "Restoring"); refused while the app runs. `--dry-run` shows the plan only |
| `punch recovery [--json]` | The restore waiting for confirmation and its reconciliation, or the last confirmed one |
| `punch recovery:confirm [--json]` | Applies the reconciliation and ends recovery mode; works while the app runs |

They read the same variables as `serve`; all but `restore` work while the app runs. Without an answer from Litestream, `punch backup` shows the lag as unknown.

## Cost

Litestream holds a read transaction on every file between its checkpoints, and its checkpoint briefly takes the write lock. Measured with the reference app's release build (4 threads, mixed reads and writes at a fixed rate, versitygw as a local S3 gateway, 2026-10-14):

| Load | p99 without | p99 with | p99.9 without | p99.9 with |
|---|---|---|---|---|
| 1,000 requests/s, 200 writes/s | 1.1 ms | 1.4 ms | 8.6 ms | 10.6 ms |
| 5,000 requests/s, 1,000 writes/s | 4.7 ms | 5.4 ms | 7.8 ms | 18.0 ms |
| saturated (wrk, 64 connections, about 6,800 writes/s) | 8 ms | 50 ms | | |

Throughput stayed the same (34,100 and 33,000 requests/s saturated). The tail at saturation is Litestream's checkpoint, about once a second at that write rate; it is the same with the writer's own checkpoints switched off. The writer's checkpoints stay on: they are cheap, and they keep the WAL in check while Litestream is down. One that a reader (Litestream) kept from copying every frame is tried again only after `checkpoint_pages` more frames, not after every write (`docs/metrics.md`).

## Testing

Specs need no bucket. `spec/backup/backup_spec.cr` and `spec/backup/verification_spec.cr` use a stand-in S3 endpoint (an `HTTP::Server` answering `GetBucketEncryption`), a stand-in control socket, a shell script in place of Litestream for the sidecar's locking and restarts, and real Litestream with a `file://` replica when it is installed (pending otherwise). `PUNCH_BACKUP_URL=file:///tmp/replica` tries it locally. To try S3 without an account, run [versitygw](https://github.com/versity/versitygw) as a local gateway (`versitygw --access KEY --secret SECRET --port 127.0.0.1:7070 posix /tmp/s3`, with `/tmp/s3/<bucket>` created) and point `PUNCH_BACKUP_URL` at it with `?endpoint=http://127.0.0.1:7070`; it does not answer `GetBucketEncryption`, so set `PUNCH_BACKUP_ENCRYPTION=provider`.
