#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
APP_DIR="${ROOT_DIR}/apps/sample-app"
# shellcheck source=lib/load_config.sh
source "${ROOT_DIR}/lib/load_config.sh"

CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"
PROJECT_ID=""
REGION="asia-northeast1"
REPOSITORY_NAME="sre-playground"
SERVICE_NAME="sre-playground"
BLUE_WEIGHT="100"
GREEN_WEIGHT="0"
BLUE_TAG="blue"
GREEN_TAG="green"
SKIP_BUILD="false"
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-}"
OTEL_ENVIRONMENT="${OTEL_ENVIRONMENT:-demo}"
GREEN_EXTRA_LATENCY_MS="${GREEN_EXTRA_LATENCY_MS:-0}"
APP_ERROR_RATE="${APP_ERROR_RATE:-0}"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/deploy_blue_green.sh [--config ./.sre_playground.env] [--project <PROJECT_ID>] [options]

options:
  --config <FILE>                Config file path (default: ./.sre_playground.env)
  --project <PROJECT_ID>         GCP project id
  --region <REGION>              GCP region (default: asia-northeast1)
  --repository <NAME>            Artifact Registry repository (default: sre-playground)
  --service-name <NAME>          Terraform service name (default: sre-playground)
  --blue-weight <0-100>          Blue traffic weight (default: 100)
  --green-weight <0-100>         Green traffic weight (default: 0)
  --blue-tag <TAG>               Blue image tag (default: blue)
  --green-tag <TAG>              Green image tag (default: green)
  --otel-traces-endpoint <URL>   OTLP HTTP traces endpoint for sample apps
  --otel-environment <VALUE>     OTel environment attribute (default: demo)
  --green-extra-latency-ms <MS>  Extra latency injected into green (default: 0)
  --app-error-rate <RATE>        Injected error rate for green, 0-1 (default: 0)
  --skip-build                   Skip docker build/push and run only terraform
  --help                         Show this help
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
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --blue-weight) BLUE_WEIGHT="$2"; shift 2 ;;
    --green-weight) GREEN_WEIGHT="$2"; shift 2 ;;
    --blue-tag) BLUE_TAG="$2"; shift 2 ;;
    --green-tag) GREEN_TAG="$2"; shift 2 ;;
    --otel-traces-endpoint) OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="$2"; shift 2 ;;
    --otel-environment) OTEL_ENVIRONMENT="$2"; shift 2 ;;
    --green-extra-latency-ms) GREEN_EXTRA_LATENCY_MS="$2"; shift 2 ;;
    --app-error-rate) APP_ERROR_RATE="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="true"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
done

[[ -n "${PROJECT_ID}" ]] || { usage; error "--project is required, or set PROJECT_ID in the config file"; }
[[ $((BLUE_WEIGHT + GREEN_WEIGHT)) -eq 100 ]] || error "blue/green weights must add up to 100"

require_cmd gcloud
require_cmd terraform
ensure_gcloud_auth

if [[ "${SKIP_BUILD}" != "true" ]]; then
  require_cmd docker
  ensure_artifact_registry_access
fi

BLUE_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${SERVICE_NAME}:${BLUE_TAG}"
GREEN_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${SERVICE_NAME}:${GREEN_TAG}"

if [[ -f "${ROOT_DIR}/credentials/gcp-key.json" ]]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${ROOT_DIR}/credentials/gcp-key.json}"
fi

export TF_VAR_project_id="${PROJECT_ID}"
export TF_VAR_region="${REGION}"

if [[ "${SKIP_BUILD}" != "true" ]]; then
  info "Building sample app image for blue: ${BLUE_IMAGE}"
  docker build \
    --build-arg APP_COLOR=blue \
    --build-arg APP_VERSION="${BLUE_TAG}" \
    -t "${BLUE_IMAGE}" \
    "${APP_DIR}"

  info "Building sample app image for green: ${GREEN_IMAGE}"
  docker build \
    --build-arg APP_COLOR=green \
    --build-arg APP_VERSION="${GREEN_TAG}" \
    -t "${GREEN_IMAGE}" \
    "${APP_DIR}"

  info "Pushing blue image"
  docker push "${BLUE_IMAGE}"

  info "Pushing green image"
  docker push "${GREEN_IMAGE}"
fi

info "Running terraform init"
terraform -chdir="${TF_DIR}" init

info "Applying terraform with blue=${BLUE_WEIGHT}, green=${GREEN_WEIGHT}"
terraform -chdir="${TF_DIR}" apply -auto-approve \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}" \
  -var="service_name=${SERVICE_NAME}" \
  -var="container_image_blue=${BLUE_IMAGE}" \
  -var="container_image_green=${GREEN_IMAGE}" \
  -var="otel_exporter_otlp_traces_endpoint=${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT}" \
  -var="otel_environment=${OTEL_ENVIRONMENT}" \
  -var="green_extra_latency_ms=${GREEN_EXTRA_LATENCY_MS}" \
  -var="app_error_rate=${APP_ERROR_RATE}" \
  -var="blue_weight=${BLUE_WEIGHT}" \
  -var="green_weight=${GREEN_WEIGHT}"

info "Deployment completed"
terraform -chdir="${TF_DIR}" output
