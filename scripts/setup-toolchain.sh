#!/usr/bin/env bash
# Installs the pinned toolchain from toolchain.env: the Crystal release, which
# brings its own standard library, checked against the SHA-256 pinned there. (CI installs it with
# crystal-lang/install-crystal instead.)
#
# Usage: scripts/setup-toolchain.sh [--github]
#   Prints the environment to use. With --github, appends it to $GITHUB_PATH
#   instead.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../toolchain.env
source "$root/toolchain.env"

github=false
for arg in "$@"; do
  case "$arg" in
    --github) github=true ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

dir="${PUNCH_TOOLCHAIN_DIR:-$HOME/.cache/punch-toolchain}"
mkdir -p "$dir"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) asset="linux-x86_64-bundled" sha256="$CRYSTAL_SHA256_LINUX_X86_64" ;;
  Linux-aarch64 | Linux-arm64) asset="linux-aarch64-bundled" sha256="$CRYSTAL_SHA256_LINUX_AARCH64" ;;
  Darwin-*) asset="darwin-universal" sha256="$CRYSTAL_SHA256_DARWIN_UNIVERSAL" ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

compiler="$dir/crystal-$CRYSTAL_VERSION"
if [ ! -x "$compiler/bin/crystal" ]; then
  url="https://github.com/crystal-lang/crystal/releases/download/$CRYSTAL_VERSION/crystal-$CRYSTAL_VERSION-1-$asset.tar.gz"
  echo "downloading $url" >&2
  tmp="$(mktemp -d "$dir/download.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --proto '=https' --proto-redir '=https' -o "$tmp/crystal.tar.gz" "$url"
  # The archive is unpacked only when it is the one toolchain.env pins.
  if command -v sha256sum >/dev/null; then actual="$(sha256sum "$tmp/crystal.tar.gz")"
  else actual="$(shasum -a 256 "$tmp/crystal.tar.gz")"; fi
  actual="${actual%% *}"
  if [ "$actual" != "$sha256" ]; then
    echo "$url has SHA-256 $actual, but toolchain.env pins $sha256; nothing was installed" >&2
    exit 1
  fi
  tar xzf "$tmp/crystal.tar.gz" -C "$tmp"
  rm -rf "$compiler"
  mv "$(dirname "$(dirname "$(find "$tmp" -path '*/bin/crystal' | head -1)")")" "$compiler"
  rm -rf "$tmp"
  trap - EXIT
fi

if [ "$github" = true ]; then
  echo "$compiler/bin" >> "$GITHUB_PATH"
else
  echo "export PATH=\"$compiler/bin:\$PATH\""
fi
