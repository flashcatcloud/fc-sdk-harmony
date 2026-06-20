#!/usr/bin/env bash
# Phase-2 auto-instrumentation acceptance driver.
#
# Drives the demo HAP on a connected HarmonyOS emulator/device via uitest+uinput
# and greps the SDK HiLog (tag "Flashcat", domain 0xF1A7) for evidence that the
# phase-2 features fire automatically:
#   A1 navigation auto-Views, A3 tap auto-Actions, A2 FlashcatHttp auto-Resource,
#   R3 event mapper (drop + URL scrub), and the batched /api/v2/rum upload.
#
# Prereqs: an emulator/device is connected and the UPDATED demo HAP is installed
# (e.g. `hdc install -r entry/build/default/outputs/default/entry-default-unsigned.hap`
# — the cold-booted emulator accepts the unsigned build; DevEco Run also works).
#
# Usage: bash docs/phase2-acceptance.sh
set -uo pipefail

HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
BUNDLE="com.flashcat.sdk.harmony"
ABILITY="EntryAbility"
PY=/tmp/fctap_center.py

# Helper: print the center "x y" of the SMALLEST non-zero-bounds node whose
# subtree text contains the needle (the clickable Button, not its zero-bounds
# inner Text node).
cat > "$PY" <<'PY'
import sys, json, re
path, needle = sys.argv[1], sys.argv[2].lower()
def bounds(s):
    m = re.findall(r'-?\d+', s or ''); return [int(v) for v in m[:4]] if len(m) >= 4 else None
def text(n):
    t = (n.get('attributes', {}).get('text') or '')
    for c in (n.get('children') or []): t += ' ' + text(c)
    return t
best = None
def walk(n):
    global best
    b = bounds(n.get('attributes', {}).get('bounds'))
    if b:
        w, h = b[2]-b[0], b[3]-b[1]
        if w > 0 and h > 0 and needle in text(n).lower():
            a = w*h
            if best is None or a < best[0]: best = (a, (b[0]+b[2])//2, (b[1]+b[3])//2)
    for c in (n.get('children') or []): walk(c)
try: walk(json.load(open(path, encoding='utf-8', errors='ignore')))
except Exception: sys.exit(0)
if best: print(f"{best[1]} {best[2]}")
PY

dump(){ $HDC shell "uitest dumpLayout -p /data/local/tmp/u.json" >/dev/null 2>&1; $HDC shell "cat /data/local/tmp/u.json" > /tmp/u.json 2>/dev/null; }
swipe_up(){ $HDC shell "uinput -T -m 660 1900 660 800 300" >/dev/null 2>&1; sleep 1; }   # reveal lower content
# tap by text, scrolling down up to 6 times to find it. NOTE: quote the whole
# uinput command to hdc shell, else arg-splitting yields "parameter error".
tap(){
  local needle="$1" i xy
  for i in 0 1 2 3 4 5 6; do
    dump; xy=$(python3 "$PY" /tmp/u.json "$needle")
    if [ -n "$xy" ]; then $HDC shell "uinput -T -c $xy" >/dev/null 2>&1; echo "  tapped '$needle' @ $xy"; sleep 1.7; return 0; fi
    swipe_up
  done
  echo "  NOT FOUND: '$needle'"; return 1
}

echo "=== device ==="; $HDC list targets
echo "=== reset app + clear log (force-stop so the scroll starts at top) ==="
$HDC shell "aa force-stop $BUNDLE" >/dev/null 2>&1; sleep 1
$HDC shell "aa start -a $ABILITY -b $BUNDLE" >/dev/null 2>&1; sleep 4
$HDC shell "hilog -r" >/dev/null 2>&1

echo "=== drive ==="
tap "Initialize SDK"                  # init + manual home view + startViewTracking + nav observer
tap "Go to Detail page"               # A1: auto stopView(home)+startView(PageDetail)
tap "Go deeper"                       # A1: auto stop(detail)+start(settings); A3: tap
tap "Back to Detail"                  # A1: auto views; A3: tap
tap "Back"                            # return to Home
tap "Add Action (tap"                 # A3: tap auto-action on home
tap 'Tap "secret"'                    # A3 tap + R3: mapper DROPS the action
tap "Auto HTTP with"                  # A2: auto resource; R3: ?token scrubbed from url
tap "Auto HTTP GET (FlashcatHttp"     # A2: auto resource, no interceptor
sleep 6                               # let requests complete + batch upload

echo ""
echo "=== A1 navigation auto-Views ==="
$HDC shell hilog -x 2>/dev/null | grep -aE "A0f1a7/Flashcat: rum\.nav:" | tail -12
echo "=== A3 tap auto-Actions ==="
$HDC shell hilog -x 2>/dev/null | grep -aE "A0f1a7/Flashcat: rum\.tap:" | tail -12
echo "=== R3 event-mapper drops ==="
$HDC shell hilog -x 2>/dev/null | grep -aE "A0f1a7/Flashcat: rum\.mapper:" | tail -6
echo "=== A2 auto Resources + uploads ==="
$HDC shell hilog -x 2>/dev/null | grep -aE "A0f1a7/Flashcat: (write: type=resource|upload: POST /api/v2/rum)" | tail -12
