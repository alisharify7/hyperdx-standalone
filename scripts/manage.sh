#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[[ -f .env ]] || { printf '[FAIL] .env does not exist. Run: make setup\n' >&2; exit 1; }
DC=(docker compose --env-file .env -f compose.yaml)

pause_menu() {
  local unused
  printf '\n'
  read -r -p 'Press Enter to return to the menu...' unused || true
}

while true; do
  clear 2>/dev/null || true
  cat <<'MENU'
HyperDX Standalone Manager
-------------------------------------------------------------------------------
  1) Health check
  2) Status / resources / storage
  3) TTL Manager
  4) Show container state
  5) Show recent logs (200 lines)
  6) Follow logs
  7) Restart HyperDX and verify health
  8) Pull configured image and recreate HyperDX
  0) Exit
MENU
  printf '\n'
  read -r -p 'Select an option: ' choice || { printf '\n'; exit 0; }

  case "$choice" in
    1)
      ./scripts/check.sh || true
      pause_menu
      ;;
    2)
      ./scripts/status.sh || true
      pause_menu
      ;;
    3)
      ./scripts/ttl.sh || true
      pause_menu
      ;;
    4)
      "${DC[@]}" ps || true
      pause_menu
      ;;
    5)
      "${DC[@]}" logs --tail=200 hyperdx || true
      pause_menu
      ;;
    6)
      printf 'Press Ctrl+C to stop following logs and return to the manager.\n\n'
      "${DC[@]}" logs -f --tail=200 hyperdx || true
      pause_menu
      ;;
    7)
      "${DC[@]}" restart hyperdx
      ./scripts/wait-healthy.sh || true
      pause_menu
      ;;
    8)
      printf '\nThis pulls the image configured in .env and recreates the HyperDX container.\n'
      read -r -p 'Type UPDATE to continue: ' confirmation || true
      if [[ "${confirmation:-}" == 'UPDATE' ]]; then
        "${DC[@]}" pull hyperdx
        "${DC[@]}" up -d --force-recreate hyperdx
        ./scripts/wait-healthy.sh || true
      else
        printf 'No changes made.\n'
      fi
      pause_menu
      ;;
    0)
      printf 'Bye.\n'
      exit 0
      ;;
    *)
      printf '[WARN] Unknown option: %s\n' "$choice" >&2
      pause_menu
      ;;
  esac
done
