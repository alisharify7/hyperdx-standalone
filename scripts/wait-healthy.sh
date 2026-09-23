#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
ok()   { printf '[ OK ] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }

[[ -f .env ]] || fail ".env does not exist. Run: make setup"
DC=(docker compose --env-file .env -f compose.yaml)

cid="$("${DC[@]}" ps -q hyperdx)"
[[ -n "$cid" ]] || fail "HyperDX container was not created"

info "Waiting for HyperDX to become healthy..."
for _ in $(seq 1 90); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
  case "$status" in
    healthy)
      ok "HyperDX is healthy"
      exec ./scripts/check.sh
      ;;
    unhealthy|exited|dead)
      docker logs --tail=100 "$cid" >&2 || true
      fail "HyperDX entered state: ${status}"
      ;;
  esac
  sleep 2
done

fail "HyperDX did not become healthy. Run: make logs"
