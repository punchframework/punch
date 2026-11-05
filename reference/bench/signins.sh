#!/usr/bin/env bash
# Concurrent sign-ins against the served app do not stall other requests:
# passwords are hashed in an execution context of their own
# (lib/punch/docs/auth.md). Measures a cheap read alone, then the same read
# while sign-ins with correct passwords keep the password hasher busy:
# ACCOUNTS accounts, a client address per request through a trusted
# proxy, so the rate limits do not refuse them first.
#
# Usage: bench/signins.sh [SECONDS] [SIGN-IN CONNECTIONS]
# Each sign-in connection pauses PAUSE_MS (1000) between requests, so 64
# connections offer about 60 sign-ins a second, more than the hasher's two
# threads take (about 28): some are refused with 503 at once.
# BIN: a built binary (default: a release build). Needs wrk.
set -euo pipefail
cd "$(dirname "$0")/.."
seconds=${1:-20} signin_connections=${2:-64}
export ACCOUNTS=${ACCOUNTS:-5000} PASSWORD="correct horse battery staple"

bin=${BIN:-tmp/bench/invoicing}
if [ -z "${BIN:-}" ]; then
  mkdir -p tmp/bench
  crystal build --release src/main.cr -o "$bin"
fi
storage=$(mktemp -d)
. bench/lib.sh
bench_prepare
export PUNCH_THREADS=${PUNCH_THREADS:-4} PUNCH_TRUSTED_PROXIES=127.0.0.1
port=$((20000 + RANDOM % 10000))
bench_start "$port" server
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; [ -n "${KEEP:-}" ] && echo "kept $storage" || rm -rf "$storage"' EXIT
bench_wait_up "$port"
url=http://127.0.0.1:$port
bench_seed "$url"

# One account signed up through the app (user 2), so its password hash is
# real; the others share that hash.
curl -sf -o /dev/null "$url/accounts/sign_up" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Signer\",\"email\":\"u2@example.org\",\"password\":\"$PASSWORD\"}"
"$bin" db:shell "$storage/primary.db" "
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < $ACCOUNTS)
  INSERT INTO users (name, created_at) SELECT 'User ' || i, (SELECT created_at FROM users WHERE id = 2) FROM n;
  INSERT INTO punch_email_identities (user_id, email, verified_at, created_at)
  SELECT id, 'u' || id || '@example.org', created_at, created_at FROM users WHERE id > 2;
  INSERT INTO punch_passwords (user_id, hash, created_at, updated_at)
  SELECT id, (SELECT hash FROM punch_passwords WHERE user_id = 2), created_at, created_at FROM users WHERE id > 2;"

read=$url/billing/invoices/42
auth="Authorization: Bearer $TOKEN"
wrk -t2 -c32 -d2s -H "$auth" "$read" >/dev/null
summary() {
  echo "$1 $(echo "$2" | awk '/Requests\/sec/{print $2}') req/s, p50 $(echo "$2" | awk '/ 50%/{print $2}')," \
    "p90 $(echo "$2" | awk '/ 90%/{print $2}'), p99 $(echo "$2" | awk '/ 99%/{print $2}'), max $(echo "$2" | awk '/Latency/{print $4; exit}')," \
    "non-2xx $(echo "$2" | awk '/Non-2xx/{n=$NF} END{print n+0}')"
}
alone=$(wrk -t2 -c32 -d"${seconds}s" --latency -H "$auth" "$read")
summary "read alone:          " "$alone"

wrk -t2 -c"$signin_connections" -d"$((seconds + 4))s" --latency -s bench/signin.lua "$url" >"$storage/signins.txt" 2>&1 &
signins=$!
sleep 2
loaded=$(wrk -t2 -c32 -d"${seconds}s" --latency -H "$auth" "$read")
wait $signins
summary "read during sign-ins:" "$loaded"
out=$(cat "$storage/signins.txt")
summary "sign-ins:            " "$out"
echo "$out" | grep "sign-in status" | sort
