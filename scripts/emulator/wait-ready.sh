#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ADB="$(adb_bin)"
"${ADB}" start-server >/dev/null

DEVICE_ID="${DEVICE_ID:-$(wait_for_device "${ADB}")}"
timeout_seconds="${BOOT_TIMEOUT:-180}"
elapsed=0

info "waiting for ${DEVICE_ID} to finish booting"

while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
  boot_completed="$("${ADB}" -s "${DEVICE_ID}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  if [[ "${boot_completed}" == "1" ]]; then
    break
  fi

  sleep 2
  elapsed=$((elapsed + 2))
done

if [[ "${boot_completed:-}" != "1" ]]; then
  die "timed out waiting for sys.boot_completed=1 on ${DEVICE_ID} after ${timeout_seconds}s."
fi

info "unlocking screen and keeping display awake"
"${ADB}" -s "${DEVICE_ID}" shell input keyevent KEYCODE_WAKEUP >/dev/null
"${ADB}" -s "${DEVICE_ID}" shell input keyevent 82 >/dev/null
"${ADB}" -s "${DEVICE_ID}" shell settings put system screen_off_timeout 2147483647 >/dev/null
"${ADB}" -s "${DEVICE_ID}" shell svc power stayon true >/dev/null

echo "DEVICE_ID=${DEVICE_ID}"
