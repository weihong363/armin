#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

APP_ID="${APP_ID:-com.ironion.armin}"
ADB="$(adb_bin)"

"${SCRIPT_DIR}/start.sh"
"${SCRIPT_DIR}/wait-ready.sh"
"${SCRIPT_DIR}/check-network.sh"
"${SCRIPT_DIR}/install-armin.sh"

DEVICE_ID="$(select_device "${ADB}")"
info "launching ${APP_ID} on ${DEVICE_ID}"
"${ADB}" -s "${DEVICE_ID}" shell monkey -p "${APP_ID}" -c android.intent.category.LAUNCHER 1 >/dev/null \
  || die "failed to launch ${APP_ID} with monkey."

echo "SMOKE_TEST_OK=true"
