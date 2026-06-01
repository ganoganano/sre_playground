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
BLUE_WEIGHT=""
GREEN_WEIGHT=""
ALLOW_EMPTY_STATE="false"

usage() {
  cat <<'EOF'
使い方:
  ./scripts/switch_traffic.sh [--config ./.sre_playground.env] [--project <PROJECT_ID>] [--to blue|green | --blue-weight N --green-weight M] [options]

options:
  --config <FILE>                Config file path (default: ./.sre_playground.env)
  --project <PROJECT_ID>         GCP project id
  --to <blue|green>              100/0 で一気に切り替える
  --blue-weight <0-100>          Blue traffic weight
  --green-weight <0-100>         Green traffic weight
  --region <REGION>              GCP region (default: asia-northeast1)
  --repository <NAME>            Artifact Registry repository (default: sre-playground)
  --service-name <NAME>          Terraform service name (default: sre-playground)
  --blue-tag <TAG>               Existing blue image tag (default: blue)
  --green-tag <TAG>              Existing green image tag (default: green)
  --allow-empty-state            Skip Terraform state safety check
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

ensure_non_empty_state() {
  local state_list

  state_list="$(terraform -chdir="${TF_DIR}" state list 2>/dev/null || true)"
  if [[ -n "${state_list}" ]]; then
    return 0
  fi

  error "$(cat <<EOF
terraform state is empty, so applying traffic weights would attempt to recreate existing resources.

Recover one of these before retrying:
  1. Restore the original infra/terraform/terraform.tfstate used for the first deploy
  2. Import the existing GCP resources into Terraform state
  3. Re-run ./scripts/deploy_blue_green.sh from the environment that still has the correct state

If you intentionally want to apply against an empty state, rerun with:
  ./scripts/switch_traffic.sh --allow-empty-state ...
EOF
)"
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
    --to)
      case "$2" in
        blue) BLUE_WEIGHT="100"; GREEN_WEIGHT="0" ;;
        green) BLUE_WEIGHT="0"; GREEN_WEIGHT="100" ;;
        *) error "--to must be blue or green" ;;
      esac
      shift 2
      ;;
    --blue-weight) BLUE_WEIGHT="$2"; shift 2 ;;
    --green-weight) GREEN_WEIGHT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --repository) REPOSITORY_NAME="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --blue-tag) BLUE_TAG="$2"; shift 2 ;;
    --green-tag) GREEN_TAG="$2"; shift 2 ;;
    --allow-empty-state) ALLOW_EMPTY_STATE="true"; shift 1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; error "unknown argument: $1" ;;
  esac
done

[[ -n "${PROJECT_ID}" ]] || { usage; error "--project is required, or set PROJECT_ID in the config file"; }
[[ -n "${BLUE_WEIGHT}" && -n "${GREEN_WEIGHT}" ]] || error "set --to or both --blue-weight and --green-weight"
[[ $((BLUE_WEIGHT + GREEN_WEIGHT)) -eq 100 ]] || error "blue/green weights must add up to 100"

command -v terraform >/dev/null 2>&1 || error "command not found: terraform"

if [[ -f "${ROOT_DIR}/credentials/gcp-key.json" ]]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${ROOT_DIR}/credentials/gcp-key.json}"
fi

BLUE_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${SERVICE_NAME}:${BLUE_TAG}"
GREEN_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY_NAME}/${SERVICE_NAME}:${GREEN_TAG}"

info "Running terraform init"
terraform -chdir="${TF_DIR}" init >/dev/null

if [[ "${ALLOW_EMPTY_STATE}" != "true" ]]; then
  ensure_non_empty_state
fi

info "Applying traffic split blue=${BLUE_WEIGHT}, green=${GREEN_WEIGHT}"
terraform -chdir="${TF_DIR}" apply -auto-approve \
  -var="project_id=${PROJECT_ID}" \
  -var="region=${REGION}" \
  -var="service_name=${SERVICE_NAME}" \
  -var="container_image_blue=${BLUE_IMAGE}" \
  -var="container_image_green=${GREEN_IMAGE}" \
  -var="blue_weight=${BLUE_WEIGHT}" \
  -var="green_weight=${GREEN_WEIGHT}"

terraform -chdir="${TF_DIR}" output traffic_split
