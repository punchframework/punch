#!/usr/bin/env bash
# Rehearses converting customers.email to an encrypted column under load:
# four releases of the app, each started beside the one before on the same
# files, as a deploy runs two processes at once,
# while bench/customers.lua loads both. Between releases, `db:encrypt`
# converts and clears with the newer one under load. Prints each wrk run's
# failed requests: every one is a request the conversion broke. Ends with
# db:audit of the last release, which must be clean.
#
# Usage: bench/convert-email.sh REV0 REV1 REV2 REV3 [SECONDS]
#   REV0  a revision before the conversion
#   REV1  release 1, from(:email): reads either, writes both
#   REV2  release 2, from(:email, clear: true)
#   REV3  release 3, the plaintext column dropped
# Each revision is built from a git worktree (debug builds). Needs wrk.
set -euo pipefail
cd "$(dirname "$0")/.."
here=$PWD
root=$(git rev-parse --show-toplevel)
prefix=$(git rev-parse --show-prefix) # punch/reference/
revs=("${1:?usage: bench/convert-email.sh REV0 REV1 REV2 REV3 [SECONDS]}" "${2:?REV1}" "${3:?REV2}" "${4:?REV3}")
seconds=${5:-20}
connections=${CONNECTIONS:-16}

work=$(mktemp -d "${TMPDIR:-/tmp}/convert-email.XXXXXX")
storage=$work/storage
mkdir -p "$storage"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for n in 0 1 2 3; do git -C "$root" worktree remove --force "$work/src-$n" 2>/dev/null || true; done
  [ -n "${KEEP:-}" ] && echo "kept $work" || rm -rf "$work"
}
trap cleanup EXIT

# Builds revision $1 into $work/bin-$2, from a worktree with this
# checkout's shards and the worktree's own Punch.
for n in 0 1 2 3; do
  src=$work/src-$n
  git -C "$root" worktree add --detach --quiet "$src" "${revs[$n]}"
  app=$src/$prefix
  mkdir -p "$app/lib"
  for dependency in "$here"/lib/*; do
    name=$(basename "$dependency")
    [ "$name" = punch ] && continue
    cp -r "$dependency" "$app/lib/$name"
  done
  ln -s "$(cd "$app/.." && pwd)" "$app/lib/punch"
  echo "building release $n (${revs[$n]})"
  (cd "$app" && crystal build src/main.cr -o "$work/bin-$n")
done

bin=$work/bin-0
. bench/lib.sh
bench_prepare
export PUNCH_THREADS=${PUNCH_THREADS:-2} PUNCH_DRAIN_DELAY_SECONDS=0 PUNCH_TRUSTED_PROXIES=127.0.0.1
port() { echo $((20000 + $1 * 1000 + RANDOM % 1000)); }

# Starts release $1 on port $2; its PID goes to the variable named $3.
start() {
  bin=$work/bin-$1
  bench_start "$2" "$3"
  pids+=("${!3}")
  bench_wait_up "$2"
}

# Loads port $1 for $seconds as wrk run $2, in the background; the PID goes to the variable named $3.
load() {
  PREFIX=$2 wrk -t2 -c"$connections" -d"${seconds}s" -s bench/customers.lua "http://127.0.0.1:$1" >"$work/wrk-$2.txt" 2>&1 &
  printf -v "$3" '%s' $!
}

report() {
  local out failed
  out=$(cat "$work/wrk-$1.txt")
  failed=$(echo "$out" | awk '/^status /{sum += $3} END {print sum + 0}')
  echo "$1: $(echo "$out" | awk '/requests in/{print $1}') requests, $failed not 2xx $(echo "$out" | grep -o 'Socket errors.*' || true)"
  echo "$out" | grep '^status ' | sed 's/^/  /' || true
}

encrypt() {
  echo "db:encrypt with release $1:"
  "$work/bin-$1" db:encrypt "$storage/primary.db" | sed 's/^/  /'
}

ports=("$(port 0)" "$(port 1)" "$(port 2)" "$(port 3)")
start 0 "${ports[0]}" app0
bench_seed "http://127.0.0.1:${ports[0]}"

load "${ports[0]}" r0-alone w
wait "$w"
for n in 1 2 3; do
  old=$((n - 1))
  start "$n" "${ports[$n]}" "app$n" # applies its migration while the old one serves
  load "${ports[$old]}" "r$old-beside-r$n" a
  load "${ports[$n]}" "r$n-beside-r$old" b
  wait "$a" "$b"
  old_pid=app$old
  kill -TERM "${!old_pid}"
  wait "${!old_pid}" || echo "release $old exited with $?" >&2
  if [ "$n" -lt 3 ]; then
    load "${ports[$n]}" "r$n-during-encrypt" c
    encrypt "$n"
    wait "$c"
  fi
done
load "${ports[3]}" r3-alone w
wait "$w"

echo
for run in r0-alone r0-beside-r1 r1-beside-r0 r1-during-encrypt r1-beside-r2 r2-beside-r1 r2-during-encrypt r2-beside-r3 r3-beside-r2 r3-alone; do
  report "$run"
done
echo
"$work/bin-3" db:audit "$storage/primary.db"
"$work/bin-3" db:shell "$storage/primary.db" "SELECT count(*) || ' customers, columns: ' || (SELECT group_concat(name, ' ') FROM pragma_table_info('customers')) FROM customers"
grep -h "error\|Error" "$storage"/serve-*.log | grep -v '"level":"info"' | head -20 || true
