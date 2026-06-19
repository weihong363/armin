#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ADB="$(adb_bin)"
DEVICE_ID="$(select_device "${ADB}")"
APK_PATH="${APK_PATH:-${REPO_ROOT}/build/app/outputs/flutter-apk/app-debug.apk}"
APP_ID="${APP_ID:-com.ironion.armin}"

if [[ ! -f "${APK_PATH}" ]]; then
  die "APK not found at ${APK_PATH}. Set APK_PATH or run flutter build apk --debug."
fi

info "installing ${APK_PATH} on ${DEVICE_ID}"
"${ADB}" -s "${DEVICE_ID}" install -r "${APK_PATH}"

echo "PACKAGE_NAME=${APP_ID}"
