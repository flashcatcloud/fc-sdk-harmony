#!/bin/bash
# Emulator E2E smoke: build → install → scripted scenarios against a local mock
# intake → assertions. Verifies the production data-quality fixes end-to-end:
# error titles, anonymous id, and crash-to-original-session attribution.
#
# Prereq: a booted HarmonyOS emulator visible in `hdc list targets`.
# Usage: bash scripts/e2e/smoke.sh [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/../.."

DEVECO=/Applications/DevEco-Studio.app/Contents
export DEVECO_SDK_HOME="$DEVECO/sdk"
export PATH="$DEVECO/tools/ohpm/bin:$DEVECO/tools/node/bin:$PATH"
HVIGORW="$DEVECO/tools/hvigor/bin/hvigorw"
HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc"
BUNDLE=com.flashcat.sdk.harmony
ABILITY=EntryAbility
PORT=19533
CAPTURE=/tmp/flashcat-e2e-capture.ndjson
HAP=entry/build/default/outputs/default/entry-default-unsigned.hap

TARGET=$("$HDC" list targets | head -1)
if [ -z "$TARGET" ] || [ "$TARGET" = "[Empty]" ]; then
  echo "No emulator/device connected (hdc list targets is empty)"; exit 2
fi
echo "==> target: $TARGET"

if [ "${1:-}" != "--skip-build" ]; then
  echo "==> building demo HAP"
  "$HVIGORW" --mode module -p module=entry@default assembleHap --no-daemon >/dev/null
fi

echo "==> (re)installing"
"$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
"$HDC" -t "$TARGET" uninstall "$BUNDLE" >/dev/null 2>&1 || true
"$HDC" -t "$TARGET" install "$HAP" | tail -1

echo "==> starting mock intake on :$PORT"
pkill -f 'mock-intake.mjs' 2>/dev/null || true
sleep 1
rm -f "$CAPTURE"
node scripts/e2e/mock-intake.mjs "$PORT" "$CAPTURE" > /tmp/flashcat-e2e-intake.log 2>&1 &
INTAKE_PID=$!
trap 'kill $INTAKE_PID 2>/dev/null || true' EXIT
sleep 1
curl -sf -X POST "http://127.0.0.1:$PORT/healthz" >/dev/null || { echo "mock intake failed to start"; cat /tmp/flashcat-e2e-intake.log; exit 2; }
rm -f "$CAPTURE"  # drop the healthcheck artifact

run_scenario() {
  local scenario=$1 settle=$2
  echo "==> scenario: $scenario"
  "$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY" \
    --ps e2e_endpoint "http://10.0.2.2:$PORT" --ps e2e_scenario "$scenario" >/dev/null
  sleep "$settle"
}

# Phase 1: events (view/action/error/rejection) — SDK flushes every 2 s.
run_scenario events 12
node scripts/e2e/assert.mjs events "$CAPTURE"

# Phase 2: crash → process exits → relaunch replays the incident.
echo "==> scenario: crash"
"$HDC" -t "$TARGET" shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
sleep 2
"$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY" \
  --ps e2e_endpoint "http://10.0.2.2:$PORT" --ps e2e_scenario crash >/dev/null
# Wait for the process to appear, then to die (the crash).
for i in $(seq 1 20); do
  PID=$("$HDC" -t "$TARGET" shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r\n ')
  [ -n "$PID" ] && break; sleep 1
done
echo "    app pid: ${PID:-none}"
for i in $(seq 1 20); do
  ALIVE=$("$HDC" -t "$TARGET" shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r\n ')
  [ -z "$ALIVE" ] && break; sleep 1
done
echo "    app exited (crash) after ${i}s"
sleep 2
run_scenario events 14
node scripts/e2e/assert.mjs crash "$CAPTURE"

echo "==> E2E SMOKE PASSED"
