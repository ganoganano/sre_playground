#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/observability/docker-compose.yml"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/stop_collector.sh
EOF
}

error() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "command not found: $1"
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
fi

require_cmd docker
docker compose version >/dev/null 2>&1 || error "docker compose is required"
[[ -f "${COMPOSE_FILE}" ]] || error "compose file was not found: ${COMPOSE_FILE}"

info "Stopping OpenTelemetry Collector"
docker compose -f "${COMPOSE_FILE}" down
