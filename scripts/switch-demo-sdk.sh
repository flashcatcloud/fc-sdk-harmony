#!/usr/bin/env bash
#
# Switch the entry demo's SDK dependencies between local source (default dev
# setup) and the published @flashcatcloud/* ohpm packages (to validate a real
# release end-to-end against the test environment).
#
#   scripts/switch-demo-sdk.sh local                # file:../flashcat-* (develop against local source)
#   scripts/switch-demo-sdk.sh published            # consume published packages, ^0.1.0
#   scripts/switch-demo-sdk.sh published "^0.2.0"   # ...a specific published range
#
# Only TWO files change; build-profile.json5 is untouched, so all SDK modules
# stay in the project. The local modules do NOT shadow the registry packages —
# ohpm resolution follows each module's oh-package dependency spec, so pointing
# entry at "^0.1.0" pulls @flashcatcloud/* from ohpm even while the source
# modules remain in the workspace.
#
#   1. entry/oh-package.json5   — the 4 @flashcatcloud/* deps
#   2. oh-package.json5         — the project-wide core override (covers the
#                                 transitive @flashcatcloud/core dep of rum/crash/trace)
#
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
VERSION="${2:-^0.1.0}"

if [[ "$MODE" != "local" && "$MODE" != "published" ]]; then
  echo "usage: $0 local|published [version]" >&2
  exit 1
fi

MODE="$MODE" VERSION="$VERSION" python3 - <<'PY'
import os, re
mode, version = os.environ["MODE"], os.environ["VERSION"]
pkgs = ["core", "rum", "trace", "crash"]

def swap(path, name_to_spec):
    s = open(path).read()
    for name, spec in name_to_spec.items():
        s = re.sub(rf'("{re.escape(name)}":\s*)"[^"]*"',
                   lambda m, spec=spec: m.group(1) + f'"{spec}"', s)
    open(path, "w").write(s)

# entry: every @flashcatcloud/* SDK dep
swap("entry/oh-package.json5",
     {f"@flashcatcloud/{p}": (f"file:../flashcat-{p}" if mode == "local" else version) for p in pkgs})

# root override: forces the transitive core dep of rum/crash/trace to match
swap("oh-package.json5",
     {"@flashcatcloud/core": ("file:./flashcat-core" if mode == "local" else version)})

print(f"demo SDK deps -> {mode}" + (f" ({version})" if mode == "published" else ""))
PY

echo "running 'ohpm install'..."
ohpm install
echo "done. build the demo with: hvigorw assembleHap -p product=default -p module=entry@default"
