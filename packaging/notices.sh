#!/usr/bin/env bash
# Writes the third-party notices of the `punch` binary: what is compiled or
# linked into it, with each license text. Run from Punch's root after
# `shards install --production`, so lib/ holds exactly the shards the binary
# contains:
#
#   packaging/notices.sh linux|macos OUT
#
# Where `apk` exists (the Alpine build image), first checks that the
# image's packages are the versions in packaging/notices/VERSIONS.
set -euo pipefail
cd "$(dirname "$0")/.."

os="${1:?usage: packaging/notices.sh linux|macos OUT}"
out="${2:?usage: packaging/notices.sh linux|macos OUT}"
notices=packaging/notices

# component version package files...
entries="$(grep -v '^#' "$notices/VERSIONS" | grep -v '^\s*$')"

if command -v apk >/dev/null; then
  status=0
  while read -r component version package _; do
    if [ "$package" = "-" ]; then
      installed="$(crystal env CRYSTAL_VERSION)" # installed from Crystal's release, not a package
    else
      installed="$(apk info -v 2>/dev/null | sed -n "s/^$package-\([0-9][^-]*\)-r[0-9]*$/\1/p")"
    fi
    if [ "$installed" != "$version" ]; then
      echo "notices: $component is ${installed:-not installed} in this image, the notices are for $version (packaging/notices/VERSIONS)" >&2
      status=1
    fi
  done <<<"$entries"
  [ $status = 0 ] || exit 1
fi

section() { printf '\n%s\n%s\n\n' "================================================================================" "$1"; }
text() { cat "$1"; [ -z "$(tail -c1 "$1")" ] || echo; }

{
  echo "Third-party notices for the punch tool"
  echo
  echo "The punch binary contains the software below, compiled or linked into"
  echo "it. Each is used under its own license, reproduced here. Punch itself"
  echo "is under the MIT License (LICENSE)."

  while read -r component version _ files; do
    case "$os-$component" in
      # Linked from the system or Homebrew on macOS, so not in that binary.
      macos-openssl | macos-libyaml | macos-zlib | macos-musl) continue ;;
    esac
    section "$component $version"
    for file in $files; do text "$notices/$file"; done
  done <<<"$entries"

  if [ "$os" = linux ]; then
    section "GCC runtime libraries (libgcc, libatomic)"
    echo "Linked statically from GCC. GNU General Public License version 3 with"
    echo "the GCC Runtime Library Exception, which allows distributing programs"
    echo "that contain them under any terms: https://www.gnu.org/licenses/gcc-exception-3.1.html"
  fi

  sqlite="$(sed -n 's/^| Version | \([0-9.]*\) |$/\1/p' vendor/sqlite/PROVENANCE.md)"
  section "SQLite${sqlite:+ $sqlite}"
  echo "The author disclaims copyright to this source code. In place of a legal"
  echo "notice, here is a blessing:"
  echo
  echo "    May you do good and not evil."
  echo "    May you find forgiveness for yourself and forgive others."
  echo "    May you share freely, never taking more than you give."
  echo
  echo "SQLite is in the public domain: https://sqlite.org/copyright.html"

  section "Turbo $(sed -n 's/^ *VERSION = "\(.*\)"$/\1/p' src/punch/assets/turbo.cr)"
  text vendor/turbo/LICENSE

  # The shards in shard.lock that are installed (development ones are not).
  awk '/^  [a-z0-9_-]+:$/ { name = substr($1, 1, length($1) - 1) } /^    version:/ { print name, $2 }' shard.lock |
    while read -r name version; do
      [ -d "lib/$name" ] || continue
      license="$(ls "lib/$name" | grep -iE '^(licen[cs]e|copying)' | head -1)"
      [ -n "$license" ] || { echo "notices: lib/$name has no license file" >&2; exit 1; }
      section "$name $version (shard)"
      text "lib/$name/$license"
    done
} >"$out"
