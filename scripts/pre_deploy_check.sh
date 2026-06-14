#!/usr/bin/env bash
# pre_deploy_check.sh
#
# Run before `flutter build` / deploy to a real device.
# Verifies connection pool behavior against a real SSH server when
# credentials are available.
#
# Usage:
#   ARMINTEST_SSH_HOST=myhost \
#   ARMINTEST_SSH_USER=myuser \
#   ARMINTEST_SSH_PASSWORD=mypass \
#   ./scripts/pre_deploy_check.sh
#
# All ARMINTEST_* variables are optional; when absent the real-SSH
# integration tests are skipped without failing the build.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Unit tests ==="
flutter test --exclude-tags real_ssh

echo ""
echo "=== Real-SSH integration tests ==="

if [[ -z "${ARMINTEST_SSH_HOST:-}" ]] || \
   [[ -z "${ARMINTEST_SSH_USER:-}" ]] || \
   [[ -z "${ARMINTEST_SSH_PASSWORD:-}" ]]; then
  echo ""
  echo "⏭  Skipped: ARMINTEST_SSH_HOST / _USER / _PASSWORD not all set."
  echo "   Set them to run _PooledControlConnection integration tests"
  echo "   against a real SSH server before deploy."
  echo ""
  echo "   Example:"
  echo "     ARMINTEST_SSH_HOST=myhost \\"
  echo "     ARMINTEST_SSH_USER=myuser \\"
  echo "     ARMINTEST_SSH_PASSWORD=mypass \\"
  echo "     ./scripts/pre_deploy_check.sh"
  exit 0
fi

echo "   Target: ${ARMINTEST_SSH_USER}@${ARMINTEST_SSH_HOST}:${ARMINTEST_SSH_PORT:-22}"
echo ""

# Run fast tests (connection reuse, error recovery).
# Exclude slow tests (25s idle timeout wait) to keep pre-deploy fast.
flutter test --tags real_ssh --exclude-tags slow test/integration/

echo ""
echo "=== All pre-deploy checks passed ==="
