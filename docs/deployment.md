# Deployment

Learn it in: [Deploying](guides/deploying.md), [Evolving a Live App](guides/evolving-a-live-app.md).

A Punch app ships as one static binary: the code, the migrations, the assets, the compiled-in credentials file, and `openapi.json` are inside it. It runs on one machine with its SQLite files on local disk, behind a reverse proxy that terminates TLS. A deploy starts the new binary next to the old one, lets the proxy move traffic over, and stops the old one gracefully. Both processes work on the same database files meanwhile, which SQLite's locking allows and Punch is built for.

The reference app has every piece: `reference/Dockerfile`, `reference/config/deploy.yml` (Kamal), and `reference/deploy/` (Caddy and systemd).

## The binary

A static binary is built on Alpine Linux against musl, so it runs on any Linux of the same architecture without libraries:

```sh
docker build -f reference/Dockerfile --target binary --output out .   # out/invoicing
docker build -f reference/Dockerfile -t invoicing .                   # the image
```

The Dockerfile pins the compiler image (the same version as `toolchain.env`) and the Litestream release, each downloaded file by its checksum. It installs the shards without development dependencies and builds with `--release --static`. Punch's vendored SQLite is built inside the image like everywhere else (`scripts/build-sqlite.sh`).

The image is `FROM scratch`: the binary, Litestream, CA certificates, and time zones, nothing else. No shell, no package manager. It runs `serve` as user 1000 with `PUNCH_ENV=production`, `PUNCH_STORAGE=/data`, and `PUNCH_HOST=0.0.0.0` on port 3000. `/data` is a volume and must be on the machine's local disk (`docs/persistence.md`).

The reference app takes Punch as a path dependency, so its build context is Punch's root and `reference/Dockerfile.dockerignore` keeps everything but sources out, keys included. An app that takes Punch from Git builds from its own directory.

## Migrations

An app declares its migrations once, in `app/setup.cr`, with the path relative to that file:

```crystal
# app/setup.cr
Punch.migrations "../db/migrations"   # embedded at compile time
```

- `serve` and `jobs` apply pending migrations at boot, before the databases open for work and before `/up` can answer 200. A failing migration stops the boot (`migration_failed`, with file, line, and column), so the proxy never switches to the new binary and the old one keeps serving.
- `PUNCH_MIGRATE=off` makes the boot refuse while migrations are pending (`migrations_pending`), for deploys that migrate in a separate step: `bin/app db:migrate` first.
- Two processes that boot at once (`serve` and `jobs`) apply each migration once: each runs in `BEGIN IMMEDIATE` and checks it is still pending.
- The binary's `db:migrate` and `db:status` use its embedded migrations and need no source tree (JSON field `source`: `binary`). The standalone `punch db:migrate` keeps working on `db/migrations/` and rewrites `db/schema.sql`.
- `punch check` fails (step `boot`) when an app with `db/migrations/` builds a binary without them.

During a deploy the old process runs against the new schema until it stops, and after a rollback an older binary runs against migrations it does not know (`unknown` in `db:status`, which does not stop it). So a migration must keep the previous release working: add in one release, remove in a later one (`docs/migrations.md`). A migration holds the write lock while it runs; the old process's writes wait up to `busy_timeout` (5 s) and then fail. Check its cost with `punch db:cost` before shipping a rebuild.

## Settings for deploys

| Variable | Default | |
|---|---|---|
| `PUNCH_ENV` | none | `production`; `serve` and `jobs` refuse to start without it, since a missing one would read as development (the image and the systemd unit set it) |
| `PUNCH_HOST` | `127.0.0.1` | `0.0.0.0` in a container (the image sets it) |
| `PUNCH_TRUSTED_PROXIES` | none | The proxy's address, so client addresses and `https` come from its headers |
| `PUNCH_DRAIN_DELAY_SECONDS` | `0` | How long a stopping process keeps accepting after `/up` turns 503. Set it above the proxy's health-check interval when the proxy finds out by polling (Caddy: 3); 0 when the proxy switches before stopping the app (kamal-proxy) |
| `PUNCH_SHUTDOWN_TIMEOUT_SECONDS` | `25` | How long requests in progress may take to finish. Keep it below the supervisor's limit before SIGKILL (`TimeoutStopSec`, Kamal's `drain_timeout`, `docker stop -t`) |
| `PUNCH_MIGRATE` | `on` | Migrations at boot, above |

## Two processes during a deploy

The new process starts while the old one runs, on another port or in another container on the same volume:

- **Database files** are shared through SQLite's locks; each process has its own writer and waits for the other's write lock (`busy_timeout`).
- **Jobs**: both processes claim jobs during the overlap, each once. Each claims only payload versions it can read, so neither fails the other's jobs (`docs/jobs.md`). On SIGTERM, running jobs finish or go back to the queue.
- **Recurring jobs** are enqueued under a unique key per run, so two schedulers enqueue each run once.
- **Litestream** runs in the process holding `litestream.lock`. The new process tries every few seconds and takes over once the old one has synced and exited (`docs/backup.md`).
- **Live pages** end their streams when the old process starts to drain; browsers reconnect, to the new process.
- **Memory caches and memory rate limits** are per process; the new process starts empty (`docs/cache.md`, `docs/rate-limits.md`).

## Shutdown

SIGTERM drains (`docs/http.md`): `/up` turns 503 and responses carry `Connection: close`; after `PUNCH_DRAIN_DELAY_SECONDS` the listener closes and idle connections close; requests in progress finish, up to `PUNCH_SHUTDOWN_TIMEOUT_SECONDS`; then jobs stop (running ones finish or go back), the outbox relay stops, the last wide events reach `ops.db`, the databases close, and Litestream syncs their last writes. A second signal exits at once.

## Kamal

`reference/config/deploy.yml` deploys the image to one host behind kamal-proxy. On `kamal deploy`, the new container boots (migrating), kamal-proxy polls its `/up` until it answers 200, switches traffic to it, waits for requests in progress on the old container (`drain_timeout`), and Kamal stops the old container with SIGTERM. kamal-proxy has switched before the app hears of it, so `PUNCH_DRAIN_DELAY_SECONDS` stays 0.

- `forward_headers: true`: with TLS on, kamal-proxy forwards `X-Forwarded-For` only when asked.
- `PUNCH_TRUSTED_PROXIES`: the subnet of Docker's `kamal` network, where kamal-proxy runs. Every container on that network may then set `X-Forwarded-For`: keep accessories that run code you do not control off it, or name kamal-proxy's address alone.
- `volumes`: one named volume on `/data`, shared by the old and the new container.
- `deploy_timeout` covers migrations at boot.
- A live page's open stream holds the old container until `drain_timeout`.

## Caddy and systemd

`reference/deploy/`: Caddy terminates TLS (and serves HTTP/2) for two upstream ports, 3000 and 3001; systemd runs `invoicing@3000` or `invoicing@3001`; `deploy.sh` alternates between them:

1. installs the new binary as a release and points `current` at it;
2. starts the idle instance, which migrates and then answers `/up` with 200;
3. once it is healthy, stops the old instance; if it does not become healthy within 60 s, it is stopped instead and the old one keeps running.

Caddy checks `/up` on both ports every second and sends everything to the first healthy one (`lb_policy first`). A stopping process answers 503 at once but keeps accepting for `PUNCH_DRAIN_DELAY_SECONDS=3`, so Caddy has moved on before its listener closes; a connection refused in between is retried on the other port (`lb_try_duration`). A rollback is `deploy.sh` with the previous release's binary.

`/up` also fails for the reasons in `docs/http.md` and `docs/backup.md` (a stopped job dispatcher, a file without a replica outside development). Behind Caddy's active checks that takes the process out of rotation, as it would with any load balancer.

## Security updates

Punch carries its own SQLite (`vendor/sqlite/`, version in `punch db`), and the image's static binary carries the OpenSSL of the build image. A fix in either reaches an app only through a rebuild: move to the Punch release that carries the new SQLite, or rebuild the image with `docker build --pull` for an OpenSSL fix, and deploy. Pin the build image by digest in the `Dockerfile` and move the pin deliberately, so a rebuild changes only what you meant. On a systemd host, install Litestream from its release with its checksum, and update it the same way.

## Measured

On the build machine (8 cores, aarch64), with the static binary from the Dockerfile; scripts in `reference/bench/`.

| | Result |
|---|---|
| Image | 28.7 MB (binary 40.7 MB uncompressed, no program interpreter); boots, migrates, serves, runs Litestream, stops on `docker stop` |
| `handover.sh kamal 40 3`: kamal-proxy, mixed load, 32 connections, 3 handovers | 398,082 requests, 0 failed, no socket errors; p50 2.4 ms, p99 109 ms |
| `handover.sh caddy 40 3`: Caddy with `/up` checks, drain delay 3 s | 385,647 requests, 0 failed, no socket errors; p50 2.5 ms, p99 24 ms |
| `handover.sh none 40 3`: SIGTERM, then a new process, no proxy | 423,199 requests, 0 non-2xx; 7 requests cut (sent on idle keep-alive connections as the drain closed them), plus refused reconnects while no process listened |
| `signins.sh 20 64`: a read with 32 connections, alone and during 64 connections of sign-ins (5,000 accounts, an address each) | read alone p50 0.96 ms, p99 10.4 ms; during sign-ins p50 1.10 ms, p99 11.0 ms; sign-ins 232 succeeded, 807 refused at once with 503 `passwords_busy`, none rate limited |

Without a proxy, a restart cannot avoid a gap, and a request a client sends on a keep-alive connection just as the drain closes it is lost; run behind one of the proxies above.
