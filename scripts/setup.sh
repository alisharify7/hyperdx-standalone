#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "Docker is not installed."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (docker compose)."
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable."

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  info "Created .env from .env.example"
fi

if grep -q '^EXPRESS_SESSION_SECRET=CHANGE_ME$' .env; then
  if command -v openssl >/dev/null 2>&1; then
    secret="$(openssl rand -hex 32)"
  else
    secret="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  fi
  sed -i "s/^EXPRESS_SESSION_SECRET=CHANGE_ME$/EXPRESS_SESSION_SECRET=${secret}/" .env
  chmod 600 .env
  ok "Generated EXPRESS_SESSION_SECRET"
fi

get_env() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 {sub("^[^=]*=", ""); print; exit}' .env
}

PUBLIC_URL="$(get_env PUBLIC_URL)"
DATA_DIR="$(get_env DATA_DIR)"
DATA_DIR="${DATA_DIR:-./volumes}"

[[ -n "$PUBLIC_URL" ]] || fail "PUBLIC_URL is empty in .env"
[[ "$PUBLIC_URL" != */ ]] || fail "PUBLIC_URL must not end with a trailing slash"

mkdir -p "$DATA_DIR/db" "$DATA_DIR/ch_data" "$DATA_DIR/ch_logs"

DC=(docker compose --env-file .env -f compose.yaml)

info "Validating Compose configuration..."
"${DC[@]}" config --quiet
ok "Compose configuration is valid"

info "Pulling HyperDX / ClickStack image..."
"${DC[@]}" pull hyperdx

info "Starting HyperDX..."
"${DC[@]}" up -d

cid="$("${DC[@]}" ps -q hyperdx)"
[[ -n "$cid" ]] || fail "HyperDX container was not created."

info "Waiting for HyperDX to become healthy..."
for _ in $(seq 1 90); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
  case "$status" in
    healthy)
      ok "HyperDX is healthy"
      break
      ;;
    unhealthy|exited|dead)
      docker logs --tail=100 "$cid" >&2 || true
      fail "HyperDX entered state: ${status}"
      ;;
  esac
  sleep 2
done

status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
[[ "$status" == "healthy" ]] || fail "HyperDX did not become healthy. Run: make logs"

./scripts/check.sh

printf '\nHyperDX is ready.\n'
printf '  Configured URL : %s\n' "$PUBLIC_URL"
printf '  UI port        : %s\n' "$(get_env UI_PORT)"
printf '  OTLP gRPC      : %s\n' "$(get_env OTLP_GRPC_PORT)"
printf '  OTLP HTTP      : %s\n' "$(get_env OTLP_HTTP_PORT)"
