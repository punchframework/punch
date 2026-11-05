#!/usr/bin/env bash
# Deploys under load: the reference app
# behind a proxy, under bench/mixed.lua, handed over from one process to the
# next several times, as deploy/deploy.sh and Kamal do. Prints wrk's count
# of failed requests: every one is a request a deploy dropped.
#
# Usage: bench/handover.sh kamal|caddy|none [SECONDS] [HANDOVERS]
#   kamal  kamal-proxy switches (KAMAL_PROXY: its binary), as with Kamal
#   caddy  Caddy with both ports and /up checks (CADDY: its binary), as
#          with deploy/Caddyfile and deploy/deploy.sh
#   none   no proxy: SIGTERM under load, then a new process on the same
#          port. Measures the shutdown alone; a client that connects
#          before the next process listens is refused, which no deploy
#          without a proxy can avoid.
# BIN: a built binary (default: a release build). Needs wrk.
set -euo pipefail
cd "$(dirname "$0")/.."
proxy=${1:?usage: bench/handover.sh kamal|caddy|none [SECONDS] [HANDOVERS]}
seconds=${2:-40} handovers=${3:-3}
connections=${CONNECTIONS:-32}

bin=${BIN:-tmp/bench/invoicing}
if [ -z "${BIN:-}" ]; then
  mkdir -p tmp/bench
  crystal build --release src/main.cr -o "$bin"
fi
work=$(mktemp -d)
storage=$work/storage
mkdir -p "$storage"
. bench/lib.sh
bench_prepare
export PUNCH_THREADS=${PUNCH_THREADS:-4} PUNCH_TRUSTED_PROXIES=127.0.0.1
ports=($((20000 + RANDOM % 10000)) $((30000 + RANDOM % 10000)))
front=$((40000 + RANDOM % 10000))
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [ -n "${KEEP:-}" ] && echo "kept $work" || rm -rf "$work"
}
trap cleanup EXIT

case "$proxy" in
  caddy) export PUNCH_DRAIN_DELAY_SECONDS=${PUNCH_DRAIN_DELAY_SECONDS:-3} ;;
  *) export PUNCH_DRAIN_DELAY_SECONDS=${PUNCH_DRAIN_DELAY_SECONDS:-0} ;;
esac

bench_start "${ports[0]}" app
pids+=("$app")
bench_wait_up "${ports[0]}"
live=0

case "$proxy" in
  kamal)
    kamal() { HOME=$work "${KAMAL_PROXY:?set KAMAL_PROXY}" "$@"; }
    kamal run --http-port "$front" --https-port $((front + 1)) >"$work/proxy.log" 2>&1 &
    pids+=($!)
    sleep 1
    kamal deploy invoicing --target "127.0.0.1:${ports[0]}" --health-check-interval 1s --drain-timeout 30s >>"$work/proxy.log" 2>&1
    url=http://127.0.0.1:$front
    ;;
  caddy)
    cat >"$work/Caddyfile" <<CADDY
{
	admin off
	auto_https off
}
:$front {
	reverse_proxy 127.0.0.1:${ports[0]} 127.0.0.1:${ports[1]} {
		lb_policy first
		lb_try_duration 10s
		lb_try_interval 100ms
		health_uri /up
		health_interval 1s
		health_timeout 2s
		health_fails 1
		health_passes 1
	}
}
CADDY
    "${CADDY:?set CADDY}" run --config "$work/Caddyfile" --adapter caddyfile >"$work/proxy.log" 2>&1 &
    pids+=($!)
    url=http://127.0.0.1:$front
    sleep 2
    ;;
  none) url=http://127.0.0.1:${ports[0]} ;;
  *) echo "unknown proxy: $proxy" >&2; exit 2 ;;
esac
bench_wait_up "${front}" 2>/dev/null || [ "$proxy" = none ]
bench_seed "$url"

# The load, while the handovers run.
wrk -t4 -c"$connections" -d"${seconds}s" --latency -s bench/mixed.lua "$url" >"$work/wrk.txt" 2>&1 &
load=$!
interval=$((seconds / (handovers + 1)))
for n in $(seq "$handovers"); do
  sleep "$interval"
  old=$app
  started=$(date +%s.%N)
  if [ "$proxy" = none ]; then
    kill -TERM "$old"
    wait "$old" || echo "process $old exited with $?" >&2
    bench_start "${ports[0]}" app
    pids+=("$app")
    bench_wait_up "${ports[0]}"
  else
    next=$((1 - live))
    bench_start "${ports[$next]}" app
    pids+=("$app")
    bench_wait_up "${ports[$next]}"
    [ "$proxy" = kamal ] && kamal deploy invoicing --target "127.0.0.1:${ports[$next]}" --health-check-interval 1s --drain-timeout 30s >>"$work/proxy.log" 2>&1
    kill -TERM "$old"
    wait "$old" || echo "process $old exited with $?" >&2
    live=$next
  fi
  echo "handover $n: $(echo "$(date +%s.%N) - $started" | bc | cut -c1-5) s"
done
wait $load
out=$(cat "$work/wrk.txt")
echo "$out"
errors=$(echo "$out" | awk '/Socket errors/{print}' )
non2xx=$(echo "$out" | awk '/Non-2xx/{print $NF}')
echo "summary: proxy=$proxy handovers=$handovers $(echo "$out" | awk '/requests in/{print $1}') requests," \
  "p50 $(echo "$out" | awk '/ 50%/{print $2}'), p99 $(echo "$out" | awk '/ 99%/{print $2}')," \
  "non-2xx ${non2xx:-0}, ${errors:-no socket errors}"
grep -h "shutdown timeout\|second signal" "$storage"/serve-*.log || true
