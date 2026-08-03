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

TARGET=$("$HDC" list targets 2>/dev/null | grep -v '\[Empty\]' | head -1 | tr -d '\r')
if [ -z "$TARGET" ]; then
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
INSTALL_OUT=$("$HDC" -t "$TARGET" install "$HAP" 2>&1 | tail -1)
echo "    $INSTALL_OUT"
case "$INSTALL_OUT" in *successfully*|*finish*) ;; *) echo "install failed"; exit 2;; esac
# Let bms finish indexing before aa start — an immediate start silently no-ops.
for i in $(seq 1 10); do
  "$HDC" -t "$TARGET" shell "bm dump -n $BUNDLE" 2>/dev/null | grep -q appId && break; sleep 1
done
sleep 2

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
  local out
  out=$("$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY" \
    --ps e2e_endpoint "http://10.0.2.2:$PORT" --ps e2e_scenario "$scenario" 2>&1)
  case "$out" in *successfully*) ;; *) echo "    aa start: $out";; esac
  # Verify the process actually came up; retry once (bms indexing race).
  local pid=""
  for i in $(seq 1 10); do
    pid=$("$HDC" -t "$TARGET" shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r\n ')
    [ -n "$pid" ] && break; sleep 1
  done
  if [ -z "$pid" ]; then
    echo "    app did not start; retrying aa start once"
    "$HDC" -t "$TARGET" shell aa start -b "$BUNDLE" -a "$ABILITY" \
      --ps e2e_endpoint "http://10.0.2.2:$PORT" --ps e2e_scenario "$scenario" >/dev/null 2>&1
    sleep 3
  fi
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
# AMS silently suppresses restarting a recently-crashed app ("start ability
# successfully" but no process is created). Cool down past the throttle window.
echo "    cooling down 45s past the AMS crash-restart throttle"
sleep 45
run_scenario events 14
node scripts/e2e/assert.mjs crash "$CAPTURE"

echo "==> E2E SMOKE PASSED"
