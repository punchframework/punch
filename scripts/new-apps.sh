#!/usr/bin/env bash
# Generates three apps with `punch new` and lets it run every step, `punch
# check` of each included: the default parts, every optional part on, every
# one off. A few minutes each. Then adds every part to the last with `punch
# generate accounts` and runs its `punch check` again, and has the first
# compare its template with the Punch it came from (`punch upgrade:diff`):
# no change.
#
#   scripts/new-apps.sh [DIR]   # DIR on local disk (SQLite's WAL); a temp directory by default
#
# Uses the punch tool in tmp/punch-check/ (scripts/check.sh builds it), or
# $PUNCH. Each app's log is DIR/<app>.log.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
punch="${PUNCH:-$root/tmp/punch-check/punch}"
case "$punch" in /*) ;; *) punch="$root/$punch" ;; esac
[ -x "$punch" ] || (cd "$root" && crystal build src/cli/main.cr -o "$punch")
work="${1:-$(mktemp -d)}"
mkdir -p "$work"
cd "$work"
rm -rf tally allon alloff

# The first commit needs an identity; CI and fresh machines have none.
if ! git config user.name >/dev/null; then
  export GIT_AUTHOR_NAME=punch GIT_COMMITTER_NAME=punch GIT_AUTHOR_EMAIL=punch@example.org GIT_COMMITTER_EMAIL=punch@example.org
fi

status=0
run() {
  local name=$1; shift
  if "$punch" new "$name" --path "$root" "$@" >"$name.log" 2>&1; then
    echo "passed  $name"
  else
    echo "failed  $name (see $work/$name.log)" >&2
    tail -40 "$name.log" >&2
    status=1
  fi
}
run tally
run allon --magic-links --organizations --languages en,de --deploy systemd
run alloff --no-second-factor --no-tokens --deploy none --ci none

if [ $status -eq 0 ]; then
  if (cd tally && "$punch" upgrade:diff --from "$root" | tee /dev/stderr | grep -q "is the same") >tally-upgrade.log 2>&1; then
    echo "passed  tally + punch upgrade:diff (no change)"
  else
    echo "failed  tally + punch upgrade:diff (see $work/tally-upgrade.log)" >&2
    tail -40 tally-upgrade.log >&2
    status=1
  fi
  if (cd alloff && for part in magic_links organizations second_factor tokens; do
        "$punch" generate accounts "$part" || exit 1
      done && "$punch" check) >alloff-generate.log 2>&1; then
    echo "passed  alloff + punch generate accounts (every part)"
  else
    echo "failed  alloff + punch generate accounts (see $work/alloff-generate.log)" >&2
    tail -40 alloff-generate.log >&2
    status=1
  fi
fi
exit $status
