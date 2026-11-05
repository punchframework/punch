#!/usr/bin/env bash
# Puts the punch tool that matches lib/punch at lib/punch/bin/punch, where
# every punch run in this app finds it (lib/punch/docs/tooling.md). From the
# release of the app's Punch version on GitHub, checked against the
# release's SHA256SUMS; built from lib/punch where Punch is a path
# dependency, where the release has no tool for this machine, or with
# --build. Run it after `shards install`. PUNCH_RELEASES_URL replaces
# https://github.com with a mirror (https:// or file://).
#
#   scripts/punch-tool.sh [--build]
set -euo pipefail
cd "$(dirname "$0")/.."

build=false
for arg in "$@"; do
  case "$arg" in
    --build) build=true ;;
    *) echo "usage: scripts/punch-tool.sh [--build]" >&2; exit 2 ;;
  esac
done

tool=lib/punch/bin/punch
[ -f lib/punch/shard.yml ] || { echo "lib/punch is missing: run shards install first" >&2; exit 1; }
version="$(sed -n 's/^version: *//p' lib/punch/shard.yml)"

if [ "$build" = false ] && [ -x "$tool" ] && "$tool" version 2>/dev/null | grep -q "^punch $version "; then
  echo "$tool is punch $version already" >&2
  exit 0
fi

# The GitHub repository shard.lock fetches Punch from; empty for a path
# dependency.
repository="$(awk '/^  punch:/ { p = 1; next } p && /^  [^ ]/ { p = 0 } p && $1 == "git:" { print $2 }' shard.lock |
  sed -e 's|\.git$||' -n -e 's|^https://github\.com/\([A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*\)/*$|\1|p')"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=linux-x86_64 ;;
  Linux-aarch64 | Linux-arm64) platform=linux-aarch64 ;;
  Darwin-arm64) platform=macos-aarch64 ;;
  *) platform= ;;
esac

if [ "$build" = true ] || [ -z "$repository" ] || [ -z "$platform" ]; then
  echo "building $tool from lib/punch" >&2
  exec crystal build lib/punch/src/cli/main.cr -o "$tool" --release
fi

name="punch-$version-$platform"
base="${PUNCH_RELEASES_URL:-https://github.com}"
case "$base" in
  https://* | file://*) ;;
  *) echo "PUNCH_RELEASES_URL starts with https:// or file://, got '$base'" >&2; exit 1 ;;
esac
url="${base%/}/$repository/releases/download/v$version"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $url/$name.tar.gz" >&2
fetch() { curl -fsSL --proto '=https,file' --proto-redir '=https' -o "$tmp/$1" "$url/$1"; }
fetch SHA256SUMS && fetch "$name.tar.gz" ||
  { echo "the release v$version of $repository has no $name.tar.gz; scripts/punch-tool.sh --build builds the tool instead" >&2; exit 1; }

expected="$(awk -v file="$name.tar.gz" '$2 == file || $2 == "*" file { print $1 }' "$tmp/SHA256SUMS")"
if command -v sha256sum >/dev/null; then actual="$(sha256sum "$tmp/$name.tar.gz")"
else actual="$(shasum -a 256 "$tmp/$name.tar.gz")"; fi
actual="${actual%% *}"
if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
  echo "$name.tar.gz has SHA-256 $actual, but the release's SHA256SUMS says '${expected}'; nothing was installed" >&2
  exit 1
fi

tar xzf "$tmp/$name.tar.gz" -C "$tmp" "$name/punch"
"$tmp/$name/punch" version | grep -q "^punch $version " ||
  { echo "the tool in $name.tar.gz is not punch $version; nothing was installed" >&2; exit 1; }
mkdir -p "$(dirname "$tool")"
mv "$tmp/$name/punch" "$tool"
echo "installed punch $version from $repository at $tool" >&2
