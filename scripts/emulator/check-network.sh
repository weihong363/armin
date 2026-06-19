#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ADB="$(adb_bin)"
DEVICE_ID="$(select_device "${ADB}")"
BRIDGE_PORT="${BRIDGE_PORT:-8080}"
BRIDGE_URL="http://10.0.2.2:${BRIDGE_PORT}/health"
BRIDGE_HOST="10.0.2.2"

info "checking public network from ${DEVICE_ID}"
if "${ADB}" -s "${DEVICE_ID}" shell ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
  info "public network is reachable via ping"
else
  die "emulator cannot reach the public internet with ping."
fi

info "checking Bridge health at ${BRIDGE_URL}"
if "${ADB}" -s "${DEVICE_ID}" shell "command -v curl >/dev/null 2>&1"; then
  "${ADB}" -s "${DEVICE_ID}" shell "curl -fsS '${BRIDGE_URL}' >/dev/null" \
    || die "Bridge health check failed at ${BRIDGE_URL}."
elif "${ADB}" -s "${DEVICE_ID}" shell "command -v wget >/dev/null 2>&1"; then
  "${ADB}" -s "${DEVICE_ID}" shell "wget -q -O - '${BRIDGE_URL}' >/dev/null" \
    || die "Bridge health check failed at ${BRIDGE_URL}."
elif "${ADB}" -s "${DEVICE_ID}" shell "command -v nc >/dev/null 2>&1"; then
  info "curl/wget unavailable; checking Bridge TCP port with nc"
  "${ADB}" -s "${DEVICE_ID}" shell "nc -z -w 5 '${BRIDGE_HOST}' '${BRIDGE_PORT}'" \
    || die "Bridge TCP check failed at ${BRIDGE_HOST}:${BRIDGE_PORT}."
else
  die "curl, wget, and nc are unavailable inside the emulator."
fi

echo "NETWORK_OK=true"
