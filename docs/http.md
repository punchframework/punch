# HTTP kernel

Learn it in: [Securing Punch Applications](guides/securing-punch-applications.md), [Operations and Routing](guides/operations-and-routing.md).

Punch serves HTTP/1.1 with the standard library's request parser and its own connection handling. TLS and HTTP/2 belong to the reverse proxy in front, such as kamal-proxy or Caddy.

```crystal
config = Punch::HTTP::Config.new(
  host: "0.0.0.0",
  port: 3000,
  trusted_proxies: Punch::HTTP::TrustedProxies.parse(["10.0.0.0/8"]),
)
server = Punch::HTTP::Server.new(config) { |context| router.call(context) }
server.run   # blocks; SIGINT or SIGTERM drains and returns
```

The handler receives a `Punch::HTTP::Context` and returns a `Punch::HTTP::Response`. In an app, the handler is the router.

## Responses

A response is a value: status, headers, and the whole body. The kernel sends it with `Content-Length` in one piece (none on 204 and 304, which have no body), never chunked: a chunked response's last chunk waits for delayed ACKs and costs 40 ms. Sockets also have `TCP_NODELAY`.

Every response gets:

| Header | Default | Notes |
|---|---|---|
| `Content-Security-Policy` | `default-src 'self'; script-src 'self' 'sha256-…'; style-src 'self' 'sha256-…'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'` | The two hashes allow the import map and Turbo's progress bar (`docs/assets.md`). With uploads in a bucket, it also allows the bucket (`docs/uploads.md`) |
| `X-Content-Type-Options` | `nosniff` | |
| `X-Frame-Options` | `DENY` | For browsers without `frame-ancestors` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | |
| `Cross-Origin-Opener-Policy`, `Cross-Origin-Resource-Policy` | `same-origin` | |
| `Cache-Control` | `no-store` | A handler that sets its own wins |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=(), payment=(), usb=()` | Change it for an app that uses one of them |
| `Strict-Transport-Security` | `max-age=63072000` | Only when the request came over HTTPS through a trusted proxy. No `includeSubDomains` |
| `X-Request-ID` | 32 random hex digits | Or a trusted proxy's well-formed `X-Request-ID` |

A header the handler sets is kept. `SecurityHeaders.new({"Referrer-Policy" => "no-referrer", "X-Frame-Options" => nil})` changes or removes defaults for the whole app.

An exception in the handler becomes a 500 with an `application/problem+json` body carrying only the status, the code `internal_server_error`, and the request ID (`docs/openapi.md`); the exception goes to the log, never to the client.

## Request bodies

`context.read_body` returns the body as a `String`, or `BodyTooLarge` above the limit, 1 MiB by default (`max_body_size`). A declared `Content-Length` above the limit is refused before anything is read; a chunked body stops being read at the limit. An operation that needs more passes its own limit: `context.read_body(limit: 10 * 1024 * 1024)`.

Multipart requests are refused with 415 before the handler runs. Files go from the browser straight to object storage, never through the app (`docs/uploads.md`).

The standard library refuses requests with both `Content-Length` and `Transfer-Encoding` (400), request lines over 8 KiB (414), and headers over 16 KiB (431).

## Timeouts

| Setting | Default | Covers |
|---|---|---|
| `read_timeout` | 120 s | A silent connection: idle between requests, or stalled while sending one. A stalled body answers 408. Longer than kamal-proxy's 90 s pool idle time, so the proxy closes first |
| `write_timeout` | 30 s | A client that stops reading the response |
| `shutdown_timeout` | 25 s | Requests still running at shutdown; below Docker's 30 s before SIGKILL |

There is no timeout on handler run time: Crystal cannot cancel a fiber. A slow handler is visible in its wide event and trace.

## Connections

Every open connection holds a file descriptor. `max_connections` caps them: by default the process's open-file limit (`ulimit -n`) less 128 kept for databases, logs, and outgoing requests. At the cap the server stops accepting until a connection closes; new clients wait in the kernel's queue. The deployment's systemd unit raises the limit to 65,536 (`LimitNOFILE`), since systemd's default of 1,024 leaves fewer than 900.

A failed `accept`, such as running out of descriptors anyway or a client that aborted its connection, is logged as `accept failed` and retried after a pause that grows from 10 ms to a second.

## Behind a proxy

Configure the proxies whose forwarded headers are believed. Nothing is trusted by default.

- The client address is the nearest address in `X-Forwarded-For` that is not a trusted proxy, walking from the right. Addresses to its left were written by the client and may be forged.
- `X-Forwarded-Proto: https` from a trusted proxy marks the request as HTTPS.
- From any other peer the headers are ignored. The first time that happens the server logs a warning, because it usually means the proxy was not configured and every client looks like the proxy.
- `TrustedProxies.parse` raises at boot for an entry that does not parse and for a range wider than /8 (`0.0.0.0/0`, or `0.0.0.0/1` with `128.0.0.0/1`), which would let any client choose its address.

## Probes and bans

Scanners ask every server on the internet for `/wp-login.php`, `/.env.backup`, or `/.git/config`. The server answers such a probe before anything else runs: 404 with no body, the security headers, and `Connection: close`. It is not traced, writes no wide event, and gets no request ID. Two probes from one address within 10 minutes ban the address: it gets 403 with no body for every path but `/up`, untraced like a probe. The first ban lasts an hour, the second a day, every further one a week; an address's count is forgotten 7 days after its last ban ended. IPv6 addresses are banned by their /64, as rate limits count them.

A path is a probe when, ignoring case,

- its last segment ends in an extension no Punch app serves: scripts of other platforms (`.php`, `.asp`, `.aspx`, `.jsp`, `.cgi`, …), backups and dumps (`.bak`, `.old`, `.swp`, `.sql`, `.sqlite`, …), archives (`.zip`, `.tar`, `.gz`, …), and configuration and keys (`.env`, `.ini`, `.conf`, `.yml`, `.log`, `.pem`, `.key`, …);
- it is, or is below, another platform's admin path: `/wp`, `/wp-admin`, `/wp-content`, `/wp-includes`, `/wp-json`, `/wordpress`, `/cgi-bin`, `/phpmyadmin`, `/pma`, `/myadmin`, `/vendor/phpunit`, `/actuator`, `/boaform`, `/hnap1`, `/_ignition`, `/manager/html`;
- or one of its segments starts with a dot: `/.env`, `/.git/config`, `/app/.aws/credentials`.

Nothing under `/.well-known/` is a probe: Apple, Google, browsers, and security researchers fetch it in good faith. Nor is anything a browser asks for on its own, such as `/favicon.ico`, `/apple-touch-icon.png`, or `/robots.txt`. A percent-encoded path is checked as sent and decoded. The full lists are `Punch::HTTP::Probes::Patterns::EXTENSIONS` and `PREFIXES`.

An app changes the list once, in `app/setup.cr`. `without` refuses an entry that is not in the list, so a typo does not go unnoticed:

```crystal
Punch::HTTP::Probes.patterns = Punch::HTTP::Probes::Patterns.default
  .with(prefixes: ["/old-admin"])
  .without(extensions: [".yml"])
```

`serve` refuses to start, and `Punch::Spec.client` raises, when a route or an asset would be answered as a probe: its visitors would be banned. Rename it, or take the pattern out.

**Who is never banned:** loopback, the trusted proxies, the addresses in `PUNCH_PROBE_ALLOW`, and private addresses (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, link-local, `fc00::/7`) that did not come through a trusted proxy. A proxy that was not configured, or Docker's port forwarding, shows every client as one such address, and a ban would lock everyone out. A probe from them is still answered 404. A forwarded header from a public address does not protect it: the header is ignored and the address is banned.

**Where bans live:** probes are counted in each process's memory. Bans are kept in `cache.db` (`punch_probe_bans`), so they survive a restart and reach the other process during a deploy: each process reads them every 30 seconds. `cache.db` is not replicated, so a restore starts without bans.

**Settings**, read at boot (`punch config` shows them):

| Variable | Default | |
|---|---|---|
| `PUNCH_PROBES` | `on` | `off` lets probes through to the router, and bans nobody |
| `PUNCH_PROBE_BAN_AFTER` | `2` | probes from one address within the window that ban it; `0` never bans |
| `PUNCH_PROBE_WINDOW_MINUTES` | `10` | the window those probes count in |
| `PUNCH_PROBE_BANS` | `1h,24h,7d` | how long the first, the second, … ban lasts; the last applies to every further one |
| `PUNCH_PROBE_ALLOW` | none | comma-separated addresses or ranges never banned, such as an office's network or an uptime monitor |

**Seeing it:** each ban is one log line under `punch.http.probes`, `address banned`, with the address, which ban it is, until when, and the first paths it asked for. The metrics `punch.http.probes`, `punch.http.refused`, `punch.http.bans`, and `punch.http.banned` count the rest (`docs/metrics.md`). The ops console lists the bans at `/_punch/bans` and lifts one (`docs/ops.md`); so do the commands:

| Command | Does |
|---|---|
| `punch bans` | Active bans, and ended ones still counted for the next, with the paths each address asked for |
| `punch bans:lift ADDRESS` | Lifts a ban and forgets the address's count; a running server lets it in within 30 seconds. An IPv6 address lifts its /64 |

## Health

`GET /up` answers `{"status":"ok"}` with 200 while every registered check passes, and 503 with the failing checks otherwise; their names and reasons go only to loopback and the trusted proxies, anyone else gets `{"status":"failing"}`. It does not reach the handler. Checks are added by later packages, such as a database ping:

```crystal
server.health_check("database") { db_reachable? ? nil : "cannot open primary.db" }
```

## Shutdown

SIGINT or SIGTERM starts a graceful shutdown; a second signal exits at once.

1. `/up` answers 503 and responses carry `Connection: close`.
2. After `drain_delay` (default 0), the server stops accepting connections and closes idle ones.
3. Requests in progress finish. After `shutdown_timeout` the remaining connections are cut.
4. Shutdown steps run in order: `server.on_shutdown("jobs") { ... }`. Jobs and the WAL checkpoint register here in later packages.

Set `drain_delay` when a load balancer polls `/up` and needs time to stop sending traffic. kamal-proxy takes the app out of rotation before stopping it, so it needs none.

## Logging and tracing

`server.process(request, peer)` runs one request in process and returns the response as a client would receive it, without binding or writing; endpoint specs use it (`docs/testing.md`).

Each request is one trace whose root span is its wide event, written by default as one JSON line on stdout after the response (`docs/tracing.md`). The server takes the tracer as its second argument: `Server.new(config, tracer) { … }`; `Punch::Trace::Tracer.off` turns it off. `GET /up` is not traced, nor are probes and banned addresses ("Probes and bans"). Unhandled exceptions are also logged under `punch.http` with the request ID.
