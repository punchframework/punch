#!/usr/bin/env bash
# Runs every check CI runs: builds the punch CLI and runs `punch check`
# (format, lint, build with statistics in tmp/build-stats/, specs on
# CRYSTAL_WORKERS threads), then `punch check` in the reference app, after
# checking that its shared files match the template
# (scripts/sync-reference.sh). With PUNCH_NEW_APPS=1, also the three apps
# of `punch new` (scripts/new-apps.sh). Arguments go to both `punch check`
# runs. The guides' examples app (docs/guides/examples/) follows the
# reference app the same way.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p tmp/punch-check
crystal build src/cli/main.cr -o tmp/punch-check/punch

status=0
tmp/punch-check/punch check "$@" || status=$?

echo "== reference app" >&2
# Its shared files come from the template (template/, punch new), and so
# do the examples app's.
PUNCH=tmp/punch-check/punch scripts/sync-reference.sh --check || status=$?
(
  cd reference
  shards check >/dev/null 2>&1 || shards install
  ../tmp/punch-check/punch check "$@"
) || status=$?

echo "== examples app" >&2
(
  cd docs/guides/examples
  shards check >/dev/null 2>&1 || shards install
  ../../../tmp/punch-check/punch check "$@"
) || status=$?

# The three apps of punch new (slow, so on demand; CI sets it).
if [ -n "${PUNCH_NEW_APPS:-}" ]; then
  echo "== punch new" >&2
  PUNCH=tmp/punch-check/punch scripts/new-apps.sh "${PUNCH_NEW_APPS_DIR:-}" || status=$?
fi
exit $status
