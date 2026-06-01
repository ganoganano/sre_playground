#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/apps/dashboard"
API_DIR="${ROOT_DIR}/apps/api"
# shellcheck source=lib/load_config.sh
source "${ROOT_DIR}/lib/load_config.sh"

CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"
API_BASE_URL="${NEXT_PUBLIC_API_BASE_URL:-http://localhost:8000}"
API_HOST="0.0.0.0"
API_PORT="8000"
HOST="0.0.0.0"
PORT="3000"
FOREGROUND="false"
DEMO_MODE="false"
RUN_DIR="${ROOT_DIR}/.run"
DASHBOARD_PID_FILE="${RUN_DIR}/dashboard.pid"
DASHBOARD_LOG_FILE="${RUN_DIR}/dashboard.log"
API_PID_FILE="${RUN_DIR}/api.pid"
API_LOG_FILE="${RUN_DIR}/api.log"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/start_dashboard.sh [--config ./.sre_playground.env] [options]

options:
  --config <FILE>          Config file path (default: ./.sre_playground.env)
  --api-base-url <URL>     Backend API base URL (default: http://localhost:8000)
  --api-host <HOST>        FastAPI bind host (default: 0.0.0.0)
  --api-port <PORT>        FastAPI port (default: 8000)
  --host <HOST>            Next.js bind host (default: 0.0.0.0)
  --port <PORT>            Next.js port (default: 3000)
  --demo-mode              Start API in read-only demo mode
  --foreground             Run in foreground
  --help                   Show this help
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

is_running() {
  local pid="$1"
  kill -0 "${pid}" >/dev/null 2>&1
}

start_background_process() {
  local name="$1"
  local pid_file="$2"
  local log_file="$3"
  shift 3

  if [[ -f "${pid_file}" ]]; then
    local existing_pid
    existing_pid="$(cat "${pid_file}")"
    if is_running "${existing_pid}"; then
      error "${name} is already running with pid ${existing_pid}. Log: ${log_file}"
    fi
    rm -f "${pid_file}"
  fi

  nohup "$@" >"${log_file}" 2>&1 < /dev/null &
  local process_pid="$!"
  echo "${process_pid}" > "${pid_file}"

  sleep 1
  if ! is_running "${process_pid}"; then
    rm -f "${pid_file}"
    error "${name} failed to start. Check log: ${log_file}"
  fi

  info "${name} started in background with pid ${process_pid}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) break ;;
  esac
done

load_sre_playground_config "${CONFIG_FILE}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-base-url) API_BASE_URL="$2"; shift 2 ;;
    --api-host) API_HOST="$2"; shift 2 ;;
    --api-port) API_PORT="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --demo-mode) DEMO_MODE="true"; shift 1 ;;
    --foreground) FOREGROUND="true"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
done

require_cmd npm
[[ -f "${DASHBOARD_DIR}/package.json" ]] || error "dashboard package.json was not found"
[[ -d "${DASHBOARD_DIR}/node_modules" ]] || error "dashboard dependencies are missing. Run: npm --prefix apps/dashboard install"
[[ -x "${API_DIR}/.venv/bin/uvicorn" ]] || error "API dependencies are missing. Run: ./scripts/bootstrap_local.sh"

mkdir -p "${RUN_DIR}"

info "Starting API"
info "API base URL: ${API_BASE_URL}"
info "API host: ${API_HOST}"
info "API port: ${API_PORT}"
info "Demo mode: ${DEMO_MODE}"
info "API log file: ${API_LOG_FILE}"

start_background_process \
  "api" \
  "${API_PID_FILE}" \
  "${API_LOG_FILE}" \
  env DEMO_MODE="${DEMO_MODE}" PYTHONPATH="${API_DIR}" "${API_DIR}/.venv/bin/uvicorn" app.main:app --host "${API_HOST}" --port "${API_PORT}"

info "Starting dashboard"
info "Host: ${HOST}"
info "Port: ${PORT}"
info "Dashboard log file: ${DASHBOARD_LOG_FILE}"

cd "${DASHBOARD_DIR}"

if [[ "${FOREGROUND}" == "true" ]]; then
  NEXT_PUBLIC_API_BASE_URL="${API_BASE_URL}" npm run dev -- --hostname "${HOST}" --port "${PORT}"
  exit 0
fi

start_background_process \
  "dashboard" \
  "${DASHBOARD_PID_FILE}" \
  "${DASHBOARD_LOG_FILE}" \
  env NEXT_PUBLIC_API_BASE_URL="${API_BASE_URL}" npm run dev -- --hostname "${HOST}" --port "${PORT}"
