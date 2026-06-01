#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
# shellcheck source=lib/load_config.sh
source "${ROOT_DIR}/lib/load_config.sh"

CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"
PROJECT_ID=""
REGION="asia-northeast1"
SERVICE_NAME="sre-playground"
REPOSITORY_NAME="sre-playground"
BLUE_TAG="blue"
GREEN_TAG="green"
ALLOW_NON_EMPTY_STATE="false"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/import_existing_infra.sh [--config ./.sre_playground.env] [options]

options:
  --config <FILE>            Config file path (default: ./.sre_playground.env)
  --project <PROJECT_ID>     GCP project id
  --region <REGION>          GCP region (default: asia-northeast1)
  --service-name <NAME>      Terraform service name (default: sre-playground)
  --repository <NAME>        Artifact Registry repository (default: sre-playground)
  --blue-tag <TAG>           Existing blue image tag (default: blue)
  --green-tag <TAG>          Existing green image tag (default: green)
  --allow-non-empty-state    Import into a non-empty Terraform state
  --help                     Show this help
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

ensure_state_is_empty() {
  local state_list

  state_list="$(terraform -chdir="${TF_DIR}" state list 2>/dev/null || true)"
  if [[ -z "${state_list}" ]]; then
    return 0
  fi

  error "$(cat <<EOF
terraform state is not empty.

This script is intended to recover an empty or lost state for already-existing infrastructure.
If you really want to import into the current state, rerun with:
  ./scripts/import_existing_infra.sh --allow-non-empty-state ...
EOF
)"
}

import_if_missing() {
  local address="$1"
  local import_id="$2"

  if terraform -chdir="${TF_DIR}" state show "${address}" >/dev/null 2>&1; then
    info "Skipping ${address}: already present in Terraform state"
    return 0
  fi

  info "Importing ${address}"
  terraform -chdir="${TF_DIR}" import \
    -var="project_id=${PROJECT_ID}" \
    -var="region=${REGION}" \
    -var="service_name=${SERVICE_NAME}" \
    -var="container_image_blue=${BLUE_IMAGE}" \
    -var="container_image_green=${GREEN_IMAGE}" \
    -var="otel_exporter_otlp_traces_endpoint=${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT}" \
    -var="otel_environment=${OTEL_ENVIRONMENT}" \
    -var="green_extra_latency_ms=${GREEN_EXTRA_LATENCY_MS}" \
    -var="app_error_rate=${APP_ERROR_RATE}" \
    "${address}" "${import_id}"
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
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --repository) REPOSITORY_NAME="$2"; shift 2 ;;
    --blue-tag) BLUE_TAG="$2"; shift 2 ;;
    --green-tag) GREEN_TAG="$2"; shift 2 ;;
    --allow-non-empty-state) ALLOW_NON_EMPTY_STATE="true"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
done

[[ -n "${PROJECT_ID}" ]] || { usage; error "--project is required, or set PROJECT_ID in the config file"; }

require_cmd terraform

if [[ -f "${ROOT_DIR}/credentials/gcp-key.json" ]]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${ROOT_DIR}/credentials/gcp-key.json}"
fi

BLUE_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${SERVICE_NAME}:${BLUE_TAG}"
GREEN_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${SERVICE_NAME}:${GREEN_TAG}"
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="${OTEL_EXPORTER_OTLP_TRACES_ENDPOINT:-}"
OTEL_ENVIRONMENT="${OTEL_ENVIRONMENT:-demo}"
GREEN_EXTRA_LATENCY_MS="${GREEN_EXTRA_LATENCY_MS:-0}"
APP_ERROR_RATE="${APP_ERROR_RATE:-0}"

BLUE_SERVICE_NAME="${SERVICE_NAME}-blue"
GREEN_SERVICE_NAME="${SERVICE_NAME}-green"
BLUE_NEG_NAME="${SERVICE_NAME}-blue-neg"
GREEN_NEG_NAME="${SERVICE_NAME}-green-neg"
BLUE_BACKEND_NAME="${SERVICE_NAME}-blue-backend"
GREEN_BACKEND_NAME="${SERVICE_NAME}-green-backend"
URL_MAP_NAME="${SERVICE_NAME}-url-map"
PROXY_NAME="${SERVICE_NAME}-http-proxy"
ADDRESS_NAME="${SERVICE_NAME}-ip"
FORWARDING_RULE_NAME="${SERVICE_NAME}-forwarding-rule"

info "Running terraform init"
terraform -chdir="${TF_DIR}" init

if [[ "${ALLOW_NON_EMPTY_STATE}" != "true" ]]; then
  ensure_state_is_empty
fi

import_if_missing \
  "google_cloud_run_v2_service.blue" \
  "projects/${PROJECT_ID}/locations/${REGION}/services/${BLUE_SERVICE_NAME}"
import_if_missing \
  "google_cloud_run_v2_service.green" \
  "projects/${PROJECT_ID}/locations/${REGION}/services/${GREEN_SERVICE_NAME}"
import_if_missing \
  "google_cloud_run_v2_service_iam_member.blue_invoker[0]" \
  "projects/${PROJECT_ID}/locations/${REGION}/services/${BLUE_SERVICE_NAME} roles/run.invoker allUsers"
import_if_missing \
  "google_cloud_run_v2_service_iam_member.green_invoker[0]" \
  "projects/${PROJECT_ID}/locations/${REGION}/services/${GREEN_SERVICE_NAME} roles/run.invoker allUsers"
import_if_missing \
  "google_compute_region_network_endpoint_group.blue" \
  "projects/${PROJECT_ID}/regions/${REGION}/networkEndpointGroups/${BLUE_NEG_NAME}"
import_if_missing \
  "google_compute_region_network_endpoint_group.green" \
  "projects/${PROJECT_ID}/regions/${REGION}/networkEndpointGroups/${GREEN_NEG_NAME}"
import_if_missing \
  "google_compute_backend_service.default" \
  "projects/${PROJECT_ID}/global/backendServices/${BLUE_BACKEND_NAME}"
import_if_missing \
  "google_compute_backend_service.green" \
  "projects/${PROJECT_ID}/global/backendServices/${GREEN_BACKEND_NAME}"
import_if_missing \
  "google_compute_url_map.default" \
  "projects/${PROJECT_ID}/global/urlMaps/${URL_MAP_NAME}"
import_if_missing \
  "google_compute_target_http_proxy.default" \
  "projects/${PROJECT_ID}/global/targetHttpProxies/${PROXY_NAME}"
import_if_missing \
  "google_compute_global_address.default" \
  "projects/${PROJECT_ID}/global/addresses/${ADDRESS_NAME}"
import_if_missing \
  "google_compute_global_forwarding_rule.default" \
  "projects/${PROJECT_ID}/global/forwardingRules/${FORWARDING_RULE_NAME}"

info "Import completed"
info "Next step: terraform -chdir=${TF_DIR} plan -var=project_id=${PROJECT_ID} -var=region=${REGION} -var=container_image_blue=${BLUE_IMAGE} -var=container_image_green=${GREEN_IMAGE}"
