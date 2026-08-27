#!/bin/bash
# Full local check: build gate (all HARs + demo HAP + unit-test compile) and
# headless unit-test execution. Run before every push; CI runs the same steps.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVECO=/Applications/DevEco-Studio.app/Contents
export DEVECO_SDK_HOME="$DEVECO/sdk"
export PATH="$DEVECO/tools/ohpm/bin:$DEVECO/tools/node/bin:$PATH"
HVIGORW="$DEVECO/tools/hvigor/bin/hvigorw"
MODULES="flashcat_core@default,flashcat_rum@default,flashcat_crash@default,flashcat_trace@default"

echo "==> unit tests (headless)"
node scripts/unit-node/run.mjs

# entry/hvigorfile.ts imports the plugin's build output, so this must run before
# any hvigor invocation.
echo "==> hvigor plugin: build"
(cd hvigor-plugin && npm install --no-audit --no-fund --silent && npm run build)

echo "==> build gate: HARs"
"$HVIGORW" --mode module -p module="$MODULES" assembleHar --no-daemon

echo "==> build gate: demo HAP"
"$HVIGORW" --mode module -p module=entry@default assembleHap --no-daemon

# The only place the hvigor plugin runs against a real task graph — hosted Linux
# CI cannot run hvigor, so a regression here is invisible to every other check.
# The endpoint is deliberately unreachable: this gates task registration and
# build-dir resolution, not the network.
echo "==> build gate: hvigor plugin task"
FLASHCAT_UPLOAD=1 FLASHCAT_API_KEY=ci-smoke FLASHCAT_SOURCEMAP_INTAKE_URL=http://127.0.0.1:1 \
  "$HVIGORW" uploadFlashcatSymbols --no-daemon --mode module -p module=entry@default -p product=default

echo "==> build gate: unit-test compile (type check)"
"$HVIGORW" --mode module -p module="$MODULES" UnitTestBuild --no-daemon

echo "ALL CHECKS PASSED"
