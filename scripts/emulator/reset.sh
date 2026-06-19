#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ADB="$(adb_bin)"
DEVICE_ID="$(select_device "${ADB}")"
APP_ID="${APP_ID:-com.ironion.armin}"
UNINSTALL="${UNINSTALL:-false}"

info "clearing app data for ${APP_ID} on ${DEVICE_ID}"
"${ADB}" -s "${DEVICE_ID}" shell pm clear "${APP_ID}" >/dev/null \
  || die "failed to clear app data for ${APP_ID}. Is it installed?"

if [[ "${UNINSTALL}" == "true" ]]; then
  info "uninstalling ${APP_ID}"
  "${ADB}" -s "${DEVICE_ID}" uninstall "${APP_ID}" >/dev/null \
    || die "failed to uninstall ${APP_ID}."
fi

echo "RESET_OK=true"
