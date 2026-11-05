#!/usr/bin/env bash
# Renders Punch's app template (template/, `punch new`) as the reference
# app and as the guides' examples app, and copies the result into
# reference/ and docs/guides/examples/, leaving the files each app owns. The
# template is the source: change a shared file there, then run this.
#
#   scripts/sync-reference.sh           # write both apps
#   scripts/sync-reference.sh --check   # fail if that would change anything (CI)
#
# Uses the punch tool in tmp/punch-check/ (scripts/check.sh builds it), or
# $PUNCH.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

check=false
[ "${1:-}" = "--check" ] && check=true
punch="${PUNCH:-tmp/punch-check/punch}"
[ -x "$punch" ] || crystal build src/cli/main.cr -o "$punch"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status=0

# sync DIR NAME OPTIONS…: renders the template as the app NAME with its
# options and compares it with DIR, skipping the files in the arrays
# `owned` and `owned_dirs`. Every file under `shared_dirs` must come from
# the template.
sync() {
  local app=$1 rendered="$work/$2"
  shift 2
  "$punch" new "$rendered" "$@" --skip-install --skip-git --path "$root" >/dev/null

  is_owned() {
    local path=$1
    for file in "${owned[@]}"; do [ "$path" = "$file" ] && return 0; done
    for dir in "${owned_dirs[@]}"; do case "$path" in "$dir"/*) return 0 ;; esac; done
    return 1
  }

  local changed=() path dir
  while IFS= read -r path; do
    is_owned "$path" && continue
    if ! cmp -s "$rendered/$path" "$app/$path"; then
      changed+=("$path")
      $check || { mkdir -p "$app/$(dirname "$path")"; cp "$rendered/$path" "$app/$path"; }
    fi
  done < <(cd "$rendered" && find . -type f ! -name '*.gen.cr' | sed 's|^\./||' | LC_ALL=C sort)

  for dir in "${shared_dirs[@]}"; do
    while IFS= read -r path; do
      is_owned "$path" && continue
      [ -e "$rendered/$path" ] && continue
      changed+=("$path (not in the template)")
      $check || rm "$app/$path"
    done < <(cd "$app" && find "$dir" -type f ! -name '*.gen.cr' | LC_ALL=C sort)
  done

  if [ ${#changed[@]} -eq 0 ]; then
    echo "$app/ matches the template."
  elif $check; then
    echo "$app/ differs from the template in:" >&2
    printf '  %s\n' "${changed[@]}" >&2
    echo "Change the template (template/), then run scripts/sync-reference.sh; never edit these files in $app/ alone." >&2
    status=1
  else
    echo "Wrote ${#changed[@]} files into $app/:"
    printf '  %s\n' "${changed[@]}"
  fi
}

# The reference app's own files: what it does beyond a new app (billing,
# its roles, layout, texts, and stylesheet), its history (migrations), and
# its build from Punch's root. Credentials are per checkout.
owned=(
  shard.yml README.md Dockerfile Dockerfile.dockerignore config/deploy.yml
  app/accounts/roles.cr app/credentials.cr app/components/layout.cr app/assets/app.css
  config/locales/en.yml config/locales/de.yml spec/spec_helper.cr spec/accounts/roles_spec.cr
)
owned_dirs=(db/migrations config/credentials)
# Directories whose every file comes from the template, so a file the
# template no longer has is removed from the reference app too.
shared_dirs=(app/accounts app/home spec/accounts config/locales/accounts deploy)
sync reference invoicing --module Invoicing --magic-links --organizations --languages en,de \
  --deploy systemd --ci none --environments development

# The examples app of the guides (docs/guides/): a new app with the
# fewest parts, plus what the guides quote that the reference app does
# not show (billing). It owns its texts, its spec helper, its migrations,
# its credentials (the alerts example adds one), and its path to Punch.
owned=(shard.yml config/locales/en.yml spec/spec_helper.cr app/credentials.cr)
owned_dirs=(db/migrations config/credentials)
shared_dirs=(app/accounts app/home spec/accounts config/locales/accounts)
sync docs/guides/examples examples --module Examples --no-second-factor --no-tokens --languages en \
  --deploy none --ci none --environments development

exit $status
