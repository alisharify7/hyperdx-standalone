#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ok()   { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f .env ]] || fail ".env does not exist"
command -v docker >/dev/null 2>&1 || fail "Docker is not installed"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is unavailable"

get_env() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 {sub("^[^=]*=", ""); print; exit}' .env
}

UI_PORT="$(get_env UI_PORT)"
CH_PORT="$(get_env CLICKHOUSE_HTTP_PORT)"
DC=(docker compose --env-file .env -f compose.yaml)

"${DC[@]}" config --quiet
ok "Compose configuration is valid"

cid="$("${DC[@]}" ps -q hyperdx)"
[[ -n "$cid" ]] || fail "HyperDX container is not running"

running="$(docker inspect --format '{{.State.Running}}' "$cid")"
[[ "$running" == "true" ]] || fail "HyperDX container is not running"
ok "HyperDX container is running"

health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
[[ "$health" == "healthy" ]] || fail "HyperDX health status is: $health"
ok "HyperDX container health is healthy"

if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://127.0.0.1:${UI_PORT:-8080}/" >/dev/null \
    || fail "HyperDX UI did not answer on localhost:${UI_PORT:-8080}"
  ok "HyperDX UI responds on port ${UI_PORT:-8080}"

  curl -fsS "http://127.0.0.1:${CH_PORT:-8123}/ping" | grep -q 'Ok' \
    || fail "ClickHouse /ping failed on localhost:${CH_PORT:-8123}"
  ok "ClickHouse responds on port ${CH_PORT:-8123}"
fi
