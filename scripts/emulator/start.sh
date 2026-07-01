#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

AVD_NAME="${AVD_NAME:-armin_test}"
HEADLESS="${HEADLESS:-false}"
EMULATOR="$(emulator_bin)"
LOG_DIR="${REPO_ROOT}/build/emulator"
LOG_FILE="${LOG_DIR}/${AVD_NAME}.log"

mkdir -p "${LOG_DIR}"

if ! "${EMULATOR}" -list-avds | grep -Fxq "${AVD_NAME}"; then
  die "AVD '${AVD_NAME}' not found. Create it with avdmanager or set AVD_NAME."
fi

args=(-avd "${AVD_NAME}" -netdelay none -netspeed full)
if [[ "${HEADLESS}" == "true" ]]; then
  args+=(-no-window -no-audio)
fi

info "starting AVD '${AVD_NAME}' with ${EMULATOR}"
info "emulator log: ${LOG_FILE}"

nohup "${EMULATOR}" "${args[@]}" >"${LOG_FILE}" 2>&1 &
echo "EMULATOR_PID=$!"
