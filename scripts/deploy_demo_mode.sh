#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_DIR="${ROOT_DIR}/apps/api"
DASHBOARD_DIR="${ROOT_DIR}/apps/dashboard"
# shellcheck source=lib/load_config.sh
source "${ROOT_DIR}/lib/load_config.sh"

CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"
PROJECT_ID=""
REGION="asia-northeast1"
REPOSITORY_NAME="sre-playground"
API_SERVICE_NAME="sre-playground-api"
DASHBOARD_SERVICE_NAME="sre-playground-dashboard"
API_TAG="latest"
DASHBOARD_TAG="latest"
SKIP_BUILD="false"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/deploy_demo_mode.sh [--config ./.sre_playground.env] [options]

options:
  --config <FILE>             Config file path (default: ./.sre_playground.env)
  --project <PROJECT_ID>      GCP project id
  --region <REGION>           GCP region (default: asia-northeast1)
  --repository <NAME>         Artifact Registry repository (default: sre-playground)
  --api-service-name <NAME>   Cloud Run service name for API (default: sre-playground-api)
  --dashboard-service-name <NAME>
                              Cloud Run service name for dashboard (default: sre-playground-dashboard)
  --api-tag <TAG>             API image tag (default: latest)
  --dashboard-tag <TAG>       Dashboard image tag (default: latest)
  --skip-build                Skip docker build/push and run only deploy
  --help                      Show this help
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

ensure_gcloud_auth() {
  gcloud auth print-access-token >/dev/null 2>&1 || error "gcloud is not authenticated. Run: gcloud auth login"
}

ensure_artifact_registry_access() {
  gcloud config set project "${PROJECT_ID}" >/dev/null
  gcloud artifacts repositories describe "${REPOSITORY_NAME}" --location="${REGION}" >/dev/null 2>&1 \
    || error "Artifact Registry repository '${REPOSITORY_NAME}' was not found in ${REGION}. Run: ./scripts/setup_gcp.sh"
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet >/dev/null
}

update_config_key() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  mkdir -p "$(dirname "${config_file}")"
  touch "${config_file}"

  if grep -q "^${key}=" "${config_file}"; then
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${config_file}"
    return 0
  fi

  printf '%s="%s"\n' "${key}" "${value}" >> "${config_file}"
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
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --repository) REPOSITORY_NAME="$2"; shift 2 ;;
    --api-service-name) API_SERVICE_NAME="$2"; shift 2 ;;
    --dashboard-service-name) DASHBOARD_SERVICE_NAME="$2"; shift 2 ;;
    --api-tag) API_TAG="$2"; shift 2 ;;
    --dashboard-tag) DASHBOARD_TAG="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="true"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
done

[[ -n "${PROJECT_ID}" ]] || { usage; error "--project is required, or set PROJECT_ID in the config file"; }

require_cmd gcloud
ensure_gcloud_auth

if [[ "${SKIP_BUILD}" != "true" ]]; then
  require_cmd docker
  ensure_artifact_registry_access
fi

API_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${API_SERVICE_NAME}:${API_TAG}"
DASHBOARD_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${DASHBOARD_SERVICE_NAME}:${DASHBOARD_TAG}"

if [[ "${SKIP_BUILD}" != "true" ]]; then
  info "Building API image: ${API_IMAGE}"
  docker build -t "${API_IMAGE}" "${API_DIR}"
  info "Pushing API image"
  docker push "${API_IMAGE}"
fi

info "Deploying API in demo mode"
gcloud run deploy "${API_SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --platform managed \
  --image "${API_IMAGE}" \
  --allow-unauthenticated \
  --set-env-vars "DEMO_MODE=true,PROBE_AGENT_URL=${PROBE_AGENT_URL:-http://localhost:8010}"

API_URL="$(gcloud run services describe "${API_SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" --format='value(status.url)')"

if [[ "${SKIP_BUILD}" != "true" ]]; then
  info "Building dashboard image: ${DASHBOARD_IMAGE}"
  docker build \
    --build-arg NEXT_PUBLIC_API_BASE_URL="${API_URL}" \
    -t "${DASHBOARD_IMAGE}" \
    "${DASHBOARD_DIR}"
  info "Pushing dashboard image"
  docker push "${DASHBOARD_IMAGE}"
fi

info "Deploying dashboard"
gcloud run deploy "${DASHBOARD_SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --platform managed \
  --image "${DASHBOARD_IMAGE}" \
  --allow-unauthenticated

DASHBOARD_URL="$(gcloud run services describe "${DASHBOARD_SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" --format='value(status.url)')"

update_config_key "${CONFIG_FILE}" "DEMO_API_URL" "${API_URL}"
update_config_key "${CONFIG_FILE}" "DEMO_DASHBOARD_URL" "${DASHBOARD_URL}"
update_config_key "${CONFIG_FILE}" "NEXT_PUBLIC_API_BASE_URL" "${API_URL}"

info "Demo API URL: ${API_URL}"
info "Demo dashboard URL: ${DASHBOARD_URL}"
info "Updated ${CONFIG_FILE}: DEMO_API_URL, DEMO_DASHBOARD_URL, NEXT_PUBLIC_API_BASE_URL"
