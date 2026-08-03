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

echo "==> build gate: HARs"
"$HVIGORW" --mode module -p module="$MODULES" assembleHar --no-daemon

echo "==> build gate: demo HAP"
"$HVIGORW" --mode module -p module=entry@default assembleHap --no-daemon

echo "==> build gate: unit-test compile (type check)"
"$HVIGORW" --mode module -p module="$MODULES" UnitTestBuild --no-daemon

echo "ALL CHECKS PASSED"
