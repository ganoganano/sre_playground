#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${ROOT_DIR}/.run"
DASHBOARD_PID_FILE="${RUN_DIR}/dashboard.pid"
API_PID_FILE="${RUN_DIR}/api.pid"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/stop_dashboard.sh
EOF
}

error() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
}

is_running() {
  local pid="$1"
  kill -0 "${pid}" >/dev/null 2>&1
}

child_pids() {
  local pid="$1"
  pgrep -P "${pid}" 2>/dev/null || true
}

terminate_pid_tree() {
  local pid="$1"
  local signal="$2"
  local child_pid

  for child_pid in $(child_pids "${pid}"); do
    terminate_pid_tree "${child_pid}" "${signal}"
  done

  kill "-${signal}" "${pid}" >/dev/null 2>&1 || true
}

stop_process() {
  local name="$1"
  local pid_file="$2"

  if [[ ! -f "${pid_file}" ]]; then
    info "${name} pid file was not found: ${pid_file}"
    return 0
  fi

  local process_pid
  process_pid="$(cat "${pid_file}")"
  if [[ -z "${process_pid}" ]]; then
    rm -f "${pid_file}"
    info "${name} pid file was empty"
    return 0
  fi

  if ! is_running "${process_pid}"; then
    rm -f "${pid_file}"
    info "${name} process ${process_pid} is not running"
    return 0
  fi

  info "Stopping ${name} pid ${process_pid}"
  terminate_pid_tree "${process_pid}" TERM

  for _ in $(seq 1 10); do
    if ! is_running "${process_pid}"; then
      rm -f "${pid_file}"
      info "${name} stopped"
      return 0
    fi
    sleep 1
  done

  info "${name} pid ${process_pid} did not stop with TERM, sending KILL"
  terminate_pid_tree "${process_pid}" KILL
  sleep 1

  if ! is_running "${process_pid}"; then
    rm -f "${pid_file}"
    info "${name} stopped"
    return 0
  fi

  error "${name} pid ${process_pid} did not stop"
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
fi

stop_process "dashboard" "${DASHBOARD_PID_FILE}"
stop_process "api" "${API_PID_FILE}"
