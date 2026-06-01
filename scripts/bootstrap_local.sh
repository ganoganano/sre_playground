#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info() {
  echo "[INFO] $*"
}

error() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "command not found: $1"
}

require_cmd python3
require_cmd npm

info "Installing API dependencies"
python3 -m venv "${ROOT_DIR}/apps/api/.venv"
"${ROOT_DIR}/apps/api/.venv/bin/pip" install -r "${ROOT_DIR}/apps/api/requirements.txt"

info "Installing probe-agent dependencies"
python3 -m venv "${ROOT_DIR}/apps/probe-agent/.venv"
"${ROOT_DIR}/apps/probe-agent/.venv/bin/pip" install -r "${ROOT_DIR}/apps/probe-agent/requirements.txt"

info "Installing dashboard dependencies"
npm --prefix "${ROOT_DIR}/apps/dashboard" install

info "Installing sample app dependencies"
npm --prefix "${ROOT_DIR}/apps/sample-app" install

cat <<EOF

[INFO] Local bootstrap completed

Start API:
  source "${ROOT_DIR}/apps/api/.venv/bin/activate"
  uvicorn app.main:app --reload --app-dir "${ROOT_DIR}/apps/api"

Start dashboard:
  NEXT_PUBLIC_API_BASE_URL=http://localhost:8000 npm --prefix "${ROOT_DIR}/apps/dashboard" run dev

Start probe-agent:
  source "${ROOT_DIR}/apps/probe-agent/.venv/bin/activate"
  uvicorn app.main:app --reload --app-dir "${ROOT_DIR}/apps/probe-agent"

Start sample app:
  npm --prefix "${ROOT_DIR}/apps/sample-app" run dev
EOF
