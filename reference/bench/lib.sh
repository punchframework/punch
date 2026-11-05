# Shared by the bench scripts: settings, a migrated and seeded database,
# and starting the app. Source it after setting `bin` (the app's binary)
# and `storage` (a directory on local disk).

# Settings for every process of the app, and the API token in TOKEN.
bench_prepare() {
  export PUNCH_STORAGE=$storage PUNCH_TRACE=off ISSUER__NAME="Bench GmbH" MAIL__DELIVERY=capture MAIL__FROM=bench@example.org
  export SECRET_KEY_BASE=${SECRET_KEY_BASE:-"1:$(date +%F):$(openssl rand -hex 32)"}
  "$bin" db:migrate >/dev/null
  # Every billing operation needs a signed-in user with a role in an
  # organization: one user, administrator of one organization, one API token.
  local now
  now="$(date -u +%FT%T).000000000Z"
  "$bin" db:shell "$storage/primary.db" "INSERT INTO users (name, created_at) VALUES ('Bench', '$now');
    INSERT INTO organizations (name, created_at) VALUES ('Bench', '$now');
    INSERT INTO punch_role_assignments (user_id, role, resource_type, resource_id, created_at)
    VALUES (1, 'accounts.roles.administrator', 'accounts.organizations', 1, '$now')"
  TOKEN=$("$bin" tokens:create --user 1 --name bench --days 1 | head -1)
  export TOKEN
}

# Starts `serve` on port $1 with its output in $storage/serve-$1.log; the
# process ID goes to the variable named $2.
bench_start() {
  PUNCH_ENV=${PUNCH_ENV:-development} PUNCH_PORT=$1 "$bin" serve >>"$storage/serve-$1.log" 2>&1 &
  printf -v "$2" '%s' $!
}

# Waits up to 30 s for /up on port $1.
bench_wait_up() {
  for _ in $(seq 300); do
    curl -sf -o /dev/null "http://127.0.0.1:$1/up" && return 0
    sleep 0.1
  done
  echo "no /up on port $1" >&2
  return 1
}

# 50 customers and 1,000 drafts, through the API at $1.
bench_seed() {
  local url=$1 auth="Authorization: Bearer $TOKEN" seed seeder
  for i in $(seq 50); do
    curl -sf "$url/billing/customers" -H 'Content-Type: application/json' -H "$auth" \
      -d "{\"name\":\"Customer $i\",\"email\":\"c$i@example.org\"}" >/dev/null
  done
  seed=$(mktemp)
  cat >"$seed" <<'LUA'
request = function()
  local body = '{"customer_id":' .. math.random(50) .. ',"currency":"EUR","lines":[{"description":"Seed","quantity":1,"unit_price":100}]}'
  return wrk.format("POST", "/billing/invoices", {["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. os.getenv("TOKEN")}, body)
end
LUA
  # Seed 1,000 drafts with one connection, then cut the rest.
  wrk -t1 -c1 -d30s -s "$seed" "$url" >/dev/null &
  seeder=$!
  until curl -sf -o /dev/null -H "$auth" "$url/billing/invoices/1000"; do sleep 0.1; done
  kill $seeder 2>/dev/null
  wait $seeder 2>/dev/null || true
  rm -f "$seed"
}
