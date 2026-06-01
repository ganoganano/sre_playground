#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/apps/otel-collector"
# shellcheck source=lib/load_config.sh
source "${ROOT_DIR}/lib/load_config.sh"

CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"
PROJECT_ID=""
REGION="asia-northeast1"
REPOSITORY_NAME="sre-playground"
OTEL_COLLECTOR_SERVICE_NAME="sre-playground-otel-collector"
OTEL_COLLECTOR_TAG="latest"
SKIP_BUILD="false"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/deploy_otel_collector.sh [--config ./.sre_playground.env] [options]

options:
  --config <FILE>           Config file path (default: ./.sre_playground.env)
  --project <PROJECT_ID>    GCP project id
  --region <REGION>         GCP region (default: asia-northeast1)
  --repository <NAME>       Artifact Registry repository (default: sre-playground)
  --service-name <NAME>     Cloud Run service name (default: sre-playground-otel-collector)
  --tag <TAG>               Docker image tag (default: latest)
  --skip-build              Skip docker build/push and run only deploy
  --help                    Show this help
EOF
}

error() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
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
    --service-name) OTEL_COLLECTOR_SERVICE_NAME="$2"; shift 2 ;;
    --tag) OTEL_COLLECTOR_TAG="$2"; shift 2 ;;
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

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${OTEL_COLLECTOR_SERVICE_NAME}:${OTEL_COLLECTOR_TAG}"

if [[ "${SKIP_BUILD}" != "true" ]]; then
  info "Building otel-collector image: ${IMAGE_URI}"
  docker build -t "${IMAGE_URI}" "${APP_DIR}"

  info "Pushing otel-collector image"
  docker push "${IMAGE_URI}"
fi

info "Deploying otel-collector to Cloud Run"
gcloud run deploy "${OTEL_COLLECTOR_SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --platform managed \
  --image "${IMAGE_URI}" \
  --allow-unauthenticated \
  --port 8080

SERVICE_URL="$(gcloud run services describe "${OTEL_COLLECTOR_SERVICE_NAME}" --project "${PROJECT_ID}" --region "${REGION}" --format='value(status.url)')"
TRACE_ENDPOINT="${SERVICE_URL}/v1/traces"

update_config_key "${CONFIG_FILE}" "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" "${TRACE_ENDPOINT}"
update_config_key "${CONFIG_FILE}" "OTEL_COLLECTOR_SERVICE_NAME" "${OTEL_COLLECTOR_SERVICE_NAME}"
update_config_key "${CONFIG_FILE}" "OTEL_COLLECTOR_TAG" "${OTEL_COLLECTOR_TAG}"

info "OTel Collector deployed"
info "OTLP HTTP traces endpoint: ${TRACE_ENDPOINT}"
info "Updated ${CONFIG_FILE}: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"
