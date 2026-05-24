#!/usr/bin/env bash

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEFAULT_CONFIG_FILE="${ROOT_DIR}/.sre_playground.env"

load_sre_playground_config() {
  local config_file="${1:-${DEFAULT_CONFIG_FILE}}"

  if [[ -f "${config_file}" ]]; then
    # shellcheck disable=SC1090
    source "${config_file}"
  fi
}
