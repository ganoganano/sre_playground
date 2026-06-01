#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/apps/probe-agent"
# shellcheck source=lib/load_config.sh
source "${ROOT_DIR}/lib/load_config.sh"

CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"
PROJECT_ID=""
REGION="asia-northeast1"
REPOSITORY_NAME="sre-playground"
PROBE_AGENT_SERVICE_NAME="sre-playground-probe-agent"
PROBE_AGENT_TAG="latest"
PROBE_TARGET_URL=""
PROBE_INTERVAL_SECONDS="5.0"
PROBE_TIMEOUT_SECONDS="5.0"
SKIP_BUILD="false"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/deploy_probe_agent.sh [--config ./.sre_playground.env] [--project <PROJECT_ID>] [options]

options:
  --config <FILE>                Config file path (default: ./.sre_playground.env)
  --project <PROJECT_ID>         GCP project id
  --region <REGION>              GCP region (default: asia-northeast1)
  --repository <NAME>            Artifact Registry repository (default: sre-playground)
  --service-name <NAME>          Cloud Run service name (default: sre-playground-probe-agent)
  --tag <TAG>                    Docker image tag (default: latest)
  --target-url <URL>             Probe target URL
  --interval-seconds <0.1-10>    Probe interval seconds (default: 5.0)
  --timeout-seconds <0.1-30>     Probe timeout seconds (default: 5.0)
  --skip-build                   Skip docker build/push and run only deploy
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
    --service-name) PROBE_AGENT_SERVICE_NAME="$2"; shift 2 ;;
    --tag) PROBE_AGENT_TAG="$2"; shift 2 ;;
    --target-url) PROBE_TARGET_URL="$2"; shift 2 ;;
    --interval-seconds) PROBE_INTERVAL_SECONDS="$2"; shift 2 ;;
    --timeout-seconds) PROBE_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="true"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
done

[[ -n "${PROJECT_ID}" ]] || { usage; error "--project is required, or set PROJECT_ID in the config file"; }
[[ -n "${PROBE_TARGET_URL}" ]] || { usage; error "--target-url is required, or set PROBE_TARGET_URL in the config file"; }

require_cmd gcloud
ensure_gcloud_auth

if [[ "${SKIP_BUILD}" != "true" ]]; then
  require_cmd docker
  ensure_artifact_registry_access
fi

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${PROBE_AGENT_SERVICE_NAME}:${PROBE_AGENT_TAG}"

if [[ "${SKIP_BUILD}" != "true" ]]; then
  info "Building probe-agent image: ${IMAGE_URI}"
  docker build -t "${IMAGE_URI}" "${APP_DIR}"

  info "Pushing probe-agent image"
  docker push "${IMAGE_URI}"
fi

info "Deploying probe-agent to Cloud Run"
gcloud run deploy "${PROBE_AGENT_SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --platform managed \
  --image "${IMAGE_URI}" \
  --allow-unauthenticated \
  --set-env-vars "PROBE_TARGET_URL=${PROBE_TARGET_URL},PROBE_INTERVAL_SECONDS=${PROBE_INTERVAL_SECONDS},PROBE_TIMEOUT_SECONDS=${PROBE_TIMEOUT_SECONDS}"

info "Probe-agent deployed"
gcloud run services describe "${PROBE_AGENT_SERVICE_NAME}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --format="value(status.url)"
