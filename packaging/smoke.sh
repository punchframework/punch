#!/bin/sh
# Runs a built `punch` once: the version it reports, its SQLite, and the
# dependency a new app gets (packaging/build-tool.sh).
#
#   packaging/smoke.sh PUNCH VERSION [REPOSITORY]
set -eu
punch="$1" version="$2" repository="${3:-}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

"$punch" version | tee /dev/stderr | grep -q "^punch $version " || { echo "punch version does not report $version" >&2; exit 1; }
"$punch" db >/dev/null
(cd "$dir" && "$punch" new smoke --skip-install --skip-git >/dev/null)
if [ -n "$repository" ]; then
  grep -q "github: $repository" "$dir/smoke/shard.yml" || { echo "a new app does not depend on $repository:" >&2; cat "$dir/smoke/shard.yml" >&2; exit 1; }
fi
