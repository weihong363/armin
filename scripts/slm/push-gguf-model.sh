#!/usr/bin/env bash
set -euo pipefail

DEVICE="${DEVICE:-emulator-5554}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
MODEL_PATH="${1:-}"
REMOTE_DIR="/data/local/tmp/armin/slm"
REMOTE_MODEL="$REMOTE_DIR/model.gguf"

if [[ -z "$MODEL_PATH" ]]; then
  echo "Usage: DEVICE=emulator-5554 $0 /path/to/model.gguf" >&2
  exit 2
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Model file not found: $MODEL_PATH" >&2
  exit 2
fi

"$ADB" -s "$DEVICE" shell "mkdir -p '$REMOTE_DIR'"
"$ADB" -s "$DEVICE" push "$MODEL_PATH" "$REMOTE_MODEL"
"$ADB" -s "$DEVICE" shell "ls -lh '$REMOTE_MODEL'"
