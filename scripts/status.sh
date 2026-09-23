#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ok()   { printf '[ OK ] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f .env ]] || fail ".env does not exist. Run: make setup"
command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is unavailable"

get_env() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 {sub("^[^=]*=", ""); print; exit}' .env
}

DATA_DIR="$(get_env DATA_DIR)"
DATA_DIR="${DATA_DIR:-./volumes}"
CH_DATABASE="$(get_env CLICKHOUSE_DATABASE)"
CH_DATABASE="${CH_DATABASE:-default}"
DC=(docker compose --env-file .env -f compose.yaml)

cid="$("${DC[@]}" ps -q hyperdx)"
[[ -n "$cid" ]] || fail "HyperDX container is not running"

printf '\nHyperDX / ClickStack status\n'
printf '%s\n' '-------------------------------------------------------------------------------'

name="$(docker inspect --format '{{.Name}}' "$cid" | sed 's#^/##')"
image="$(docker inspect --format '{{.Config.Image}}' "$cid")"
state="$(docker inspect --format '{{.State.Status}}' "$cid")"
health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$cid")"
started="$(docker inspect --format '{{.State.StartedAt}}' "$cid")"
restarts="$(docker inspect --format '{{.RestartCount}}' "$cid")"

printf 'Container : %s\n' "$name"
printf 'Image     : %s\n' "$image"
printf 'State     : %s\n' "$state"
printf 'Health    : %s\n' "$health"
printf 'Started   : %s\n' "$started"
printf 'Restarts  : %s\n' "$restarts"

printf '\nRuntime resources\n'
printf '%s\n' '-------------------------------------------------------------------------------'
docker stats --no-stream --format 'CPU={{.CPUPerc}}  MEM={{.MemUsage}}  MEM%={{.MemPerc}}  NET={{.NetIO}}  BLOCK={{.BlockIO}}' "$cid" || true

printf '\nPersistent storage\n'
printf '%s\n' '-------------------------------------------------------------------------------'
for path in "$DATA_DIR/db" "$DATA_DIR/ch_data" "$DATA_DIR/ch_logs"; do
  if [[ -e "$path" ]]; then
    printf '%-28s %s\n' "$path" "$(du -sh "$path" 2>/dev/null | awk '{print $1}')"
  else
    printf '%-28s %s\n' "$path" 'missing'
  fi
done

ch_client=()
if docker exec "$cid" clickhouse-client --version >/dev/null 2>&1; then
  ch_client=(clickhouse-client)
elif docker exec "$cid" clickhouse client --version >/dev/null 2>&1; then
  ch_client=(clickhouse client)
else
  warn "clickhouse-client was not found inside the container; skipping ClickHouse table report."
  exit 0
fi

if [[ ! "$CH_DATABASE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  warn "Unsafe CLICKHOUSE_DATABASE value; skipping ClickHouse table report."
  exit 0
fi

printf '\nClickHouse database: %s\n' "$CH_DATABASE"
printf '%s\n' '-------------------------------------------------------------------------------'

query="
SELECT
  table,
  sum(rows) AS rows,
  formatReadableSize(sum(bytes_on_disk)) AS size,
  count() AS active_parts
FROM system.parts
WHERE active AND database = '${CH_DATABASE}'
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC
FORMAT PrettyCompact
"

docker exec -i "$cid" "${ch_client[@]}" --query "$query" || warn "Could not query ClickHouse part statistics."

printf '\nTTL summary\n'
printf '%s\n' '-------------------------------------------------------------------------------'
query="
SELECT
  name AS table,
  if(position(create_table_query, ' TTL ') > 0, 'configured', 'not set') AS ttl
FROM system.tables
WHERE database = '${CH_DATABASE}'
  AND position(engine, 'MergeTree') > 0
  AND name IN (
    'otel_logs',
    'otel_traces',
    'otel_metrics_gauge',
    'otel_metrics_sum',
    'otel_metrics_histogram',
    'otel_metrics_exponential_histogram',
    'otel_metrics_summary',
    'hyperdx_sessions'
  )
ORDER BY name
FORMAT PrettyCompact
"

docker exec -i "$cid" "${ch_client[@]}" --query "$query" || warn "Could not query TTL summary."

ok "Status report completed"
