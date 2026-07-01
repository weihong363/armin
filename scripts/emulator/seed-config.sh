#!/usr/bin/env bash
# seed-config.sh
#
# Seeds the emulator app database with hosts and project paths from
# armin_config.json. Must be re-run after every emulator cold boot
# or app data clear.
#
# Usage:
#   DEVICE_ID=emulator-5554 ./scripts/emulator/seed-config.sh
#
# The script:
#   1. Builds debug APK if not present.
#   2. Installs APK on the target device.
#   3. Creates a pre-seeded SQLite database from armin_config.json.
#   4. Pushes the database into the app's internal data directory.
#   5. Force-stops the app so it picks up the seeded database on next launch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/emulator/lib.sh
source "${SCRIPT_DIR}/lib.sh"

APP_ID="${APP_ID:-com.ironion.armin}"
ADB="$(adb_bin)"
DEVICE_ID="$(select_device "${ADB}")"
APK_PATH="${APK_PATH:-${REPO_ROOT}/build/app/outputs/flutter-apk/app-debug.apk}"
CONFIG_JSON="${REPO_ROOT}/scripts/armin_config.json"
SEED_DB="/tmp/armin_seed.db"

# ── Build APK ──────────────────────────────────────────────────────
if [[ ! -f "${APK_PATH}" ]]; then
  info "building debug APK..."
  (cd "${REPO_ROOT}" && flutter build apk --debug)
fi

# ── Install APK ────────────────────────────────────────────────────
info "installing APK on ${DEVICE_ID}..."
"${ADB}" -s "${DEVICE_ID}" install -r "${APK_PATH}"
info "APK installed"

# ── Force-stop to clear in-memory state ─────────────────────────────
"${ADB}" -s "${DEVICE_ID}" shell am force-stop "${APP_ID}" 2>/dev/null || true
sleep 1

# ── Build seed database ─────────────────────────────────────────────
info "building seed database from ${CONFIG_JSON}..."
rm -f "${SEED_DB}"

python3 -c "
import json, sqlite3, sys

with open('${CONFIG_JSON}') as f:
    config = json.load(f)

db = sqlite3.connect('${SEED_DB}')
db.execute('PRAGMA journal_mode=WAL')

# Schema must match _createHistoryTables in SQLiteRuntimePersistenceStore
db.execute('''
CREATE TABLE IF NOT EXISTS hosts (
  host_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''')
db.execute('''
CREATE TABLE IF NOT EXISTS project_paths (
  project_path_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''')
db.execute('''
CREATE TABLE IF NOT EXISTS task_sessions (
  task_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''')
db.execute('''
CREATE TABLE IF NOT EXISTS runtime_tasks (
  task_id TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''')
db.execute('''
CREATE TABLE IF NOT EXISTS runtime_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL,
  type TEXT NOT NULL,
  created_at TEXT NOT NULL,
  payload TEXT NOT NULL
)
''')

for host in config.get('hosts', []):
    db.execute(
        'INSERT OR REPLACE INTO hosts(host_id, updated_at, payload) VALUES(?,?,?)',
        (host['id'], host['updatedAt'], json.dumps(host, ensure_ascii=False))
    )
    print(f'  seed host: {host[\"id\"]} ({host[\"name\"]})')

for proj in config.get('projectPaths', []):
    db.execute(
        'INSERT OR REPLACE INTO project_paths(project_path_id, updated_at, payload) VALUES(?,?,?)',
        (proj['id'], proj['updatedAt'], json.dumps(proj, ensure_ascii=False))
    )
    print(f'  seed project: {proj[\"id\"]} ({proj[\"name\"]})')

db.commit()
db.close()
print('Seed database created.')
"

# ── Push seed database to device ────────────────────────────────────
info "pushing seed database to ${DEVICE_ID}..."
DB_DIR="/data/data/${APP_ID}/databases"
DB_FILE="${DB_DIR}/armin_runtime.db"

# Push to a temp location first (run-as can't read from /data/local/tmp directly in some setups)
TEMP_DB="/data/local/tmp/armin_seed.db"
"${ADB}" -s "${DEVICE_ID}" push "${SEED_DB}" "${TEMP_DB}"

# Use run-as to copy into app's internal databases directory
"${ADB}" -s "${DEVICE_ID}" shell "
  run-as ${APP_ID} mkdir -p ${DB_DIR} 2>/dev/null || true
  run-as ${APP_ID} cp ${TEMP_DB} ${DB_FILE}
  run-as ${APP_ID} rm -f ${DB_FILE}-wal ${DB_FILE}-shm
"

# Cleanup temp file
"${ADB}" -s "${DEVICE_ID}" shell "rm -f ${TEMP_DB}"
rm -f "${SEED_DB}"

info "seed complete — hosts and projects written to ${DB_FILE}"

# ── Seed host passwords from macOS Keychain ─────────────────────────
#
# Passwords are NOT stored in armin_config.json (git-tracked).
# Instead, they are kept in macOS Keychain and written to a temporary
# seed file on the device. The app imports them into its platform
# secure storage on next launch, then deletes the seed file.
#
# To store a password: ./scripts/emulator/store-host-password.sh

SEED_PW_FILE="/data/local/tmp/armin_seed_passwords.json"
APP_PW_FILE="/data/data/${APP_ID}/files/armin_seed_passwords.json"
SEED_PW_TMP="/tmp/armin_seed_pw.json"
rm -f "${SEED_PW_TMP}"

# Build password seed JSON from Keychain (or ARMINTEST_SSH_PASSWORD env var).
python3 -c "
import json, subprocess, sys

config = json.load(open('${CONFIG_JSON}'))
pw_map = {}
for host in config.get('hosts', []):
    hid = host['id']
    pw = ''
    # Try macOS Keychain
    try:
        r = subprocess.run(['security','find-generic-password','-s',f'armin-host-{hid}','-w'],
                          capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            pw = r.stdout.strip()
    except Exception:
        pass
    # Env var fallback
    if not pw:
        import os
        pw = os.environ.get('ARMINTEST_SSH_PASSWORD', '')
    if pw:
        pw_map[hid] = pw
        print(f'  seed password: {hid}')

if pw_map:
    json.dump(pw_map, open('${SEED_PW_TMP}', 'w'))
    print(f'Password seed file created ({len(pw_map)} host(s)).')
else:
    print('No passwords to seed (store via store-host-password.sh or set ARMINTEST_SSH_PASSWORD).')
"

# Push password seed file if it was created
if [[ -f "${SEED_PW_TMP}" ]]; then
  info "pushing password seed to ${DEVICE_ID}..."
  "${ADB}" -s "${DEVICE_ID}" push "${SEED_PW_TMP}" "${SEED_PW_FILE}"
  "${ADB}" -s "${DEVICE_ID}" shell "
    run-as ${APP_ID} mkdir -p /data/data/${APP_ID}/files
    run-as ${APP_ID} cp ${SEED_PW_FILE} ${APP_PW_FILE}
    rm -f ${SEED_PW_FILE}
  "
  rm -f "${SEED_PW_TMP}"
fi

echo "SEED_OK=true"
