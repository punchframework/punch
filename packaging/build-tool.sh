#!/usr/bin/env bash
# Builds the `punch` tool for a release, from the committed files (never the
# working tree): on Linux one static binary, built in the pinned Alpine image
# with Docker; on macOS a binary built with the Crystal on the PATH. Packs it
# with Punch's license, the notices of what is linked into it, and the
# installer of the pinned Crystal (scripts/setup-toolchain.sh with
# toolchain.env), after running it once (packaging/smoke.sh):
#
#   packaging/build-tool.sh [--repository OWNER/NAME] [--arch x86_64|aarch64] OUTDIR
#
# Writes OUTDIR/punch-VERSION-OS-ARCH.tar.gz. --repository is the GitHub
# repository new apps depend on (`punch new`); without it they depend on
# the checkout by path, which suits only a local build. --arch (Linux) builds
# for another architecture through Docker's emulation, slowly.
set -euo pipefail

# Pinned like toolchain.env: moving it means checking packaging/notices/.
IMAGE=crystallang/crystal:1.22.0-alpine@sha256:db85dfd6a75c9ed2c9e83c4d2a4dba370fe2eabdabf301dc16c4fd699113192c

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

repository=""
arch=""
outdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repository) repository="${2:?--repository needs OWNER/NAME}"; shift 2 ;;
    --arch) arch="${2:?--arch needs x86_64 or aarch64}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$outdir" ] || usage; outdir="$1"; shift ;;
  esac
done
[ -n "$outdir" ] || usage
if [ -n "$repository" ] && ! [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "--repository is OWNER/NAME, got '$repository'" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^version: *//p' "$root/shard.yml")"
mkdir -p "$outdir"
outdir="$(cd "$outdir" && pwd)"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) echo "unsupported system: $(uname -s)" >&2; exit 1 ;;
esac
arch="${arch:-$(uname -m)}"
case "$arch" in
  x86_64 | amd64) arch=x86_64 platform=linux/amd64 ;;
  aarch64 | arm64) arch=aarch64 platform=linux/arm64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
[ "$os" = linux ] || [ "$arch" = "$(uname -m | sed 's/arm64/aarch64/')" ] || { echo "--arch is for Linux builds" >&2; exit 1; }

name="punch-$version-$os-$arch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/$name"

# The committed tree of Punch's root (a subdirectory of the repository or
# its top).
prefix="$(git -C "$root" rev-parse --show-prefix)"
git -C "$(git -C "$root" rev-parse --show-toplevel)" archive "HEAD:$prefix" | tar -x -C "$work/src"
[ -f "$work/src/shard.lock" ] || { echo "the committed tree has no shard.lock" >&2; exit 1; }
if [ -n "$(git -C "$root" status --porcelain -- .)" ]; then
  echo "note: uncommitted changes are not in the build" >&2
fi

if [ "$os" = linux ]; then
  docker run --rm --platform "$platform" -v "$work:/work" -e PUNCH_REPOSITORY="$repository" "$IMAGE" sh -euc '
    trap "chown -R '"$(id -u):$(id -g)"' /work" EXIT
    apk add --no-cache -q bash file >/dev/null
    cd /work/src
    shards install --production --frozen
    crystal build --static --release src/cli/main.cr -o /work/punch
    file /work/punch | grep -q "static" || { file /work/punch; echo "not a static binary" >&2; exit 1; }
    packaging/notices.sh linux /work/THIRD_PARTY_NOTICES.txt
    packaging/smoke.sh /work/punch "$0" "$1"
  ' "$version" "$repository"
else
  (
    cd "$work/src"
    shards install --production --frozen
    PUNCH_REPOSITORY="$repository" crystal build --release src/cli/main.cr -o "$work/punch"
    packaging/notices.sh macos "$work/THIRD_PARTY_NOTICES.txt"
    packaging/smoke.sh "$work/punch" "$version" "$repository"
  )
  # Libraries it loads at run time: the system's, or Homebrew's (OpenSSL,
  # LibYAML), which building an app needs anyway.
  otool -L "$work/punch" | tail -n +2 | awk '{print $1}' | tee "$work/dylibs" >&2
  if grep -vE '^(/usr/lib/|/System/|/opt/homebrew/)' "$work/dylibs"; then
    echo "links a library from elsewhere (above)" >&2
    exit 1
  fi
fi

cp "$work/punch" "$work/THIRD_PARTY_NOTICES.txt" "$work/$name/"
cp "$work/src/LICENSE" "$work/src/toolchain.env" "$work/$name/"
# The pinned Crystal's installer, so the archive is all a new machine needs.
mkdir -p "$work/$name/scripts"
cp "$work/src/scripts/setup-toolchain.sh" "$work/$name/scripts/"
tar -czf "$outdir/$name.tar.gz" -C "$work" "$name"
echo "wrote $outdir/$name.tar.gz" >&2
