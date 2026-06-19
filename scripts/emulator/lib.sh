#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

info() {
  echo "==> $*"
}

die() {
  echo "error: $*" >&2
  exit 1
}

find_android_tool() {
  local tool="$1"
  local relative_path="$2"
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  local default_macos_sdk="${HOME}/Library/Android/sdk"

  if [[ -n "${sdk_root}" && -x "${sdk_root}/${relative_path}" ]]; then
    echo "${sdk_root}/${relative_path}"
    return 0
  fi

  if [[ -x "${default_macos_sdk}/${relative_path}" ]]; then
    echo "${default_macos_sdk}/${relative_path}"
    return 0
  fi

  if command -v "${tool}" >/dev/null 2>&1; then
    command -v "${tool}"
    return 0
  fi

  die "${tool} not found. Install Android SDK Platform Tools/Emulator and set ANDROID_HOME or ANDROID_SDK_ROOT."
}

adb_bin() {
  find_android_tool "adb" "platform-tools/adb"
}

emulator_bin() {
  find_android_tool "emulator" "emulator/emulator"
}

list_ready_devices() {
  local adb="$1"
  "${adb}" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

select_device() {
  local adb="$1"
  local configured="${DEVICE_ID:-}"
  local devices=()
  local device

  if [[ -n "${configured}" ]]; then
    echo "${configured}"
    return 0
  fi

  while IFS= read -r device; do
    [[ -n "${device}" ]] && devices+=("${device}")
  done < <(list_ready_devices "${adb}")

  if [[ "${#devices[@]}" -eq 0 ]]; then
    die "no adb device is ready. Run scripts/emulator/wait-ready.sh first."
  fi

  if [[ "${#devices[@]}" -gt 1 ]]; then
    printf 'error: more than one device/emulator is connected:\n' >&2
    printf '  %s\n' "${devices[@]}" >&2
    die "set DEVICE_ID=<device id> and retry."
  fi

  echo "${devices[0]}"
}

wait_for_device() {
  local adb="$1"
  local timeout_seconds="${READY_TIMEOUT:-180}"
  local elapsed=0
  local devices=()
  local device

  "${adb}" start-server >/dev/null

  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    devices=()
    while IFS= read -r device; do
      [[ -n "${device}" ]] && devices+=("${device}")
    done < <(list_ready_devices "${adb}")

    if [[ "${#devices[@]}" -eq 1 ]]; then
      echo "${devices[0]}"
      return 0
    fi

    if [[ "${#devices[@]}" -gt 1 ]]; then
      printf 'error: more than one device/emulator is connected:\n' >&2
      printf '  %s\n' "${devices[@]}" >&2
      die "set DEVICE_ID=<device id> and retry."
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  die "timed out waiting for adb device after ${timeout_seconds}s."
}
