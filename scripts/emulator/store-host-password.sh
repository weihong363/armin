#!/usr/bin/env bash
# store-host-password.sh
#
# Stores a host SSH password in macOS Keychain for use by seed-config.sh.
# The password is never written to any plaintext file tracked by git.
#
# Usage:
#   ./scripts/emulator/store-host-password.sh
#
# The script prompts interactively for the password (hidden input).
# To use non-interactively, set ARMINTEST_SSH_PASSWORD env var.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Default host ID — matches the host in armin_config.json
HOST_ID="${1:-host-local-mac}"
SERVICE_NAME="armin-host-${HOST_ID}"
ACCOUNT_NAME="${2:-ironion}"

# Check if already stored
if security find-generic-password -s "${SERVICE_NAME}" -a "${ACCOUNT_NAME}" -w &>/dev/null; then
  echo "Password already exists in Keychain for host '${HOST_ID}'."
  read -r -p "Overwrite? [y/N] " answer
  if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    echo "Keeping existing password."
    exit 0
  fi
  security delete-generic-password -s "${SERVICE_NAME}" -a "${ACCOUNT_NAME}" &>/dev/null || true
fi

# Get password: env var first, then prompt
PASSWORD="${ARMINTEST_SSH_PASSWORD:-}"
if [[ -z "${PASSWORD}" ]]; then
  read -r -s -p "Enter SSH password for host '${HOST_ID}': " PASSWORD
  echo
  if [[ -z "${PASSWORD}" ]]; then
    die "Password cannot be empty."
  fi
fi

# Store in macOS Keychain
security add-generic-password \
  -s "${SERVICE_NAME}" \
  -a "${ACCOUNT_NAME}" \
  -w "${PASSWORD}" \
  -U

echo "Password stored in macOS Keychain (service: ${SERVICE_NAME})."
echo "You can now run 'make integration-test' — seed-config.sh will use this password."
