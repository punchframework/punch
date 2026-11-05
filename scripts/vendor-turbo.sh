#!/usr/bin/env bash
# Vendors Turbo into vendor/turbo/: the ES module build from the npm
# package, checked against the registry's integrity value, its license from
# the release's tag (the package has none), and the constants Punch embeds
# with it (src/punch/assets/turbo.cr).
#
#   scripts/vendor-turbo.sh 8.0.23
#
# Needs curl and node. Node runs only here: it evaluates Turbo's own code
# for the progress bar's inline style, whose SHA-256 the
# Content-Security-Policy allows. Apps never need either.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="${1:?usage: scripts/vendor-turbo.sh VERSION}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

meta="$work/meta.json"
curl -fsS "https://registry.npmjs.org/@hotwired/turbo/$version" -o "$meta"
tarball="$(node -e 'console.log(require(process.argv[1]).dist.tarball)' "$meta")"
integrity="$(node -e 'console.log(require(process.argv[1]).dist.integrity)' "$meta")"
license="$(node -e 'console.log(require(process.argv[1]).license)' "$meta")"
[ "$license" = "MIT" ] || { echo "Turbo $version is licensed $license, not MIT: check before vendoring" >&2; exit 1; }

curl -fsS "$tarball" -o "$work/turbo.tgz"
actual="sha512-$(node -e 'const c=require("crypto");process.stdout.write(c.createHash("sha512").update(require("fs").readFileSync(process.argv[1])).digest("base64"))' "$work/turbo.tgz")"
[ "$actual" = "$integrity" ] || { echo "integrity mismatch: registry $integrity, download $actual" >&2; exit 1; }
tar xzf "$work/turbo.tgz" -C "$work"

source="$work/package/dist/turbo.es2017-esm.js"
mkdir -p vendor/turbo
cp "$source" vendor/turbo/turbo.js
curl -fsS "https://raw.githubusercontent.com/hotwired/turbo/v$version/MIT-LICENSE" -o vendor/turbo/LICENSE
sha256="$(sha256sum vendor/turbo/turbo.js | cut -d' ' -f1)"

# The progress bar's stylesheet as Turbo writes it into a <style> element:
# its helpers and the class's static getter, evaluated as Turbo would.
progress="$(node - "$source" <<'EOF'
const fs = require("fs"), crypto = require("crypto");
const src = fs.readFileSync(process.argv[2], "utf8");
const cut = (from, to) => {
  const start = src.indexOf(from), end = src.indexOf(to, start);
  if (start < 0 || end < 0) throw new Error(`Turbo's source changed: ${from} not found`);
  return src.slice(start, end);
};
const helpers = cut("function unindent(", "function uuid(");
const progressBar = cut("class ProgressBar {", "  hiding = false") + "}";
const css = new Function(`${helpers}\n${progressBar}\nreturn ProgressBar.defaultCSS;`)();
process.stdout.write("sha256-" + crypto.createHash("sha256").update(css, "utf8").digest("base64"));
EOF
)"

cat > vendor/turbo/PROVENANCE.md <<EOF
# Turbo

\`turbo.js\` is \`dist/turbo.es2017-esm.js\` from the npm package
\`@hotwired/turbo\` $version (MIT License, © 37signals LLC), unchanged. The
package has no license file: \`LICENSE\` is \`MIT-LICENSE\` from the tag
\`v$version\` of https://github.com/hotwired/turbo.

| | |
|---|---|
| Package | $tarball |
| npm integrity | \`$integrity\` (checked) |
| SHA-256 of \`turbo.js\` | \`$sha256\` |
| Progress bar style, CSP source | \`'$progress'\` |

Written by \`scripts/vendor-turbo.sh $version\`, which also writes
\`src/punch/assets/turbo.cr\`. A spec checks the file against the SHA-256.
EOF

cat > src/punch/assets/turbo.cr <<EOF
module Punch::Assets
  # The vendored Turbo (\`vendor/turbo/\`), written by
  # \`scripts/vendor-turbo.sh\`; do not edit.
  module Turbo
    VERSION = "$version"
    SHA256  = "$sha256"
    # The CSP source for the stylesheet of Turbo's progress bar, which Turbo
    # writes into a \`<style>\` element.
    PROGRESS_BAR_STYLE = "'$progress'"
  end
end
EOF
echo "vendored Turbo $version ($sha256)" >&2
