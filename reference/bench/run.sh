#!/usr/bin/env bash
# Latency under mixed read and write load (the baselines are in the
# README): a release build of the reference app, seeded, under wrk with
# bench/mixed.lua. Usage: bench/run.sh [THREADS] [CONNECTIONS] [SECONDS];
# PAGES=1 also measures two pages.
# Needs wrk. The database goes to a temporary directory on local disk.
set -euo pipefail
cd "$(dirname "$0")/.."
threads=${1:-4} connections=${2:-64} seconds=${3:-10}

mkdir -p tmp/bench
crystal build --release src/main.cr -o tmp/bench/invoicing
storage=$(mktemp -d)
port=$((20000 + RANDOM % 10000))
bin=tmp/bench/invoicing
. bench/lib.sh
bench_prepare
export PUNCH_THREADS=$threads
bench_start "$port" server
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; [ -n "${KEEP:-}" ] && echo "kept $storage" || rm -rf "$storage"' EXIT
bench_wait_up "$port"
url=http://127.0.0.1:$port
auth="Authorization: Bearer $TOKEN"
bench_seed "$url"

wrk -t4 -c"$connections" -d2s -s bench/mixed.lua "$url" >/dev/null
out=$(wrk -t4 -c"$connections" -d"${seconds}s" --latency -s bench/mixed.lua "$url")
echo "$out"
non2xx=$(echo "$out" | awk '/Non-2xx/{print $NF}')
echo "summary: threads=$threads connections=$connections $(echo "$out" | awk '/Requests\/sec/{print $2}') req/s," \
  "p50 $(echo "$out" | awk '/ 50%/{print $2}'), p90 $(echo "$out" | awk '/ 90%/{print $2}')," \
  "p99 $(echo "$out" | awk '/ 99%/{print $2}'), non-2xx ${non2xx:-0}"

# With PAGES=1, the pages as a browser asks for them (Accept: text/html):
# one invoice, and the list at 50 a page.
if [ -n "${PAGES:-}" ]; then
  for path in /billing/invoices/42 "/billing/invoices?limit=50"; do
    page=$(wrk -t4 -c"$connections" -d"${seconds}s" --latency -H "$auth" -H "Accept: text/html,*/*;q=0.8" "$url$path")
    echo "page $path: $(echo "$page" | awk '/Requests\/sec/{print $2}') req/s," \
      "p50 $(echo "$page" | awk '/ 50%/{print $2}'), p99 $(echo "$page" | awk '/ 99%/{print $2}')," \
      "$(curl -s -H "$auth" -H 'Accept: text/html' "$url$path" | wc -c) bytes, non-2xx $(echo "$page" | awk '/Non-2xx/{n=$NF} END{print n+0}')"
  done
fi
