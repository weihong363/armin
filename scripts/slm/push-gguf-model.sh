#!/usr/bin/env bash
set -euo pipefail

DEVICE="${DEVICE:-emulator-5554}"
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
MODEL_PATH="${1:-}"
PACKAGE="com.ironion.armin"
STAGING_MODEL="/data/local/tmp/armin-model.gguf"
APP_MODEL_DIR="files/slm"
APP_MODEL="$APP_MODEL_DIR/model.gguf"

if [[ -z "$MODEL_PATH" ]]; then
  echo "Usage: DEVICE=emulator-5554 $0 /path/to/model.gguf" >&2
  exit 2
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Model file not found: $MODEL_PATH" >&2
  exit 2
fi

"$ADB" -s "$DEVICE" push "$MODEL_PATH" "$STAGING_MODEL"
"$ADB" -s "$DEVICE" shell "run-as '$PACKAGE' mkdir -p '$APP_MODEL_DIR'"
"$ADB" -s "$DEVICE" shell "run-as '$PACKAGE' cp '$STAGING_MODEL' '$APP_MODEL'"
"$ADB" -s "$DEVICE" shell "run-as '$PACKAGE' ls -lh '$APP_MODEL'"
"$ADB" -s "$DEVICE" shell "rm -f '$STAGING_MODEL'"
