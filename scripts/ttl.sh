#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f .env ]] || fail ".env does not exist. Run: make setup"

get_env() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 {sub("^[^=]*=", ""); print; exit}' .env
}

container_name="$(get_env CONTAINER_NAME)"
clickhouse_port="$(get_env CLICKHOUSE_HTTP_PORT)"
clickhouse_database="$(get_env CLICKHOUSE_DATABASE)"
ttl_backup_dir="$(get_env TTL_BACKUP_DIR)"

export CH_CONTAINER="${CH_CONTAINER:-${container_name:-hyperdx}}"
export CH_DATABASE="${CH_DATABASE:-${clickhouse_database:-default}}"
export CH_HTTP_URL="${CH_HTTP_URL:-http://127.0.0.1:${clickhouse_port:-8123}}"
export BACKUP_DIR="${BACKUP_DIR:-${ttl_backup_dir:-./backups/ttl}}"

mkdir -p "$BACKUP_DIR"
exec ./scripts/ttl-manager.sh "$@"
