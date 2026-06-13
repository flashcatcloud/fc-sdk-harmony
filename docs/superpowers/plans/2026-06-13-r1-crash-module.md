# Round 1 — `flashcat-crash` Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a new `flashcat-crash` HAR module that captures native (C/C++ `.so`) and non-native (ArkTS/JS) crashes plus app freezes via `hiAppEvent`, and reports them as RUM `is_crash` error events.

**Architecture:** A `FlashcatCrash.enable()` registers a `CrashFeature` against the core. The feature installs a `hiAppEvent` watcher for `APP_CRASH` + `APP_FREEZE`. `hiAppEvent` itself persists the crash and **replays it on the next launch**, so no custom cross-death persistence is needed. Each delivered system event is converted by a **pure `CrashEventMapper`** into a loosely-typed bus message targeted at the RUM feature; `RumFeature.onReceive` maps it to `monitor.reportError(..., isCrash=true)`. The mapper is pure (Record→Record) so it is fully unit-testable without a device; only the thin watcher wiring is deferred to on-device verification.

**Tech Stack:** ArkTS (HarmonyOS NEXT), `@kit.PerformanceAnalysisKit` (`hiAppEvent`), `@ohos/hypium` tests, hvigor build.

**ArkTS constraints (already established in this repo):** no object spread `{...}`, no bare `delete` on `Record` (use `Map`), no `any`, explicit `Record<string, Object>` event shapes, catch param is untyped — narrow with `instanceof Error`.

---

### Task 1: Scaffold the `flashcat-crash` module

**Files:**
- Create: `flashcat-crash/oh-package.json5`
- Create: `flashcat-crash/build-profile.json5`
- Create: `flashcat-crash/hvigorfile.ts`
- Create: `flashcat-crash/obfuscation-rules.txt`
- Create: `flashcat-crash/Index.ets`
- Create: `flashcat-crash/src/main/module.json5`
- Modify: `build-profile.json5` (root — register the module)
- Modify: `oh-package.json5` (root — add `overrides` entry mirroring rum/trace)

- [ ] **Step 1: Copy the trace module's config files as the template**

`flashcat-crash/oh-package.json5` — mirror `flashcat-trace/oh-package.json5`, but:
```json5
{
  "name": "@flashcatcloud/crash",
  "version": "0.1.0",
  "description": "FlashCat HarmonyOS crash reporting (hiAppEvent: native + ArkTS + freeze)",
  "main": "Index.ets",
  "author": "flashcat",
  "license": "Apache-2.0",
  "dependencies": {
    "@flashcatcloud/core": "0.1.0"
  }
}
```
Copy `build-profile.json5`, `hvigorfile.ts`, `obfuscation-rules.txt`, `src/main/module.json5` verbatim from `flashcat-trace/` (they are module-name-agnostic). Confirm `obfuscation-rules.txt` includes the `consumerFiles` entries already present in trace's copy.

- [ ] **Step 2: Register the module in the root `build-profile.json5`**

Add to the `modules` array (mirror the `flashcat-trace` entry exactly, name → `flashcat_crash`, srcPath → `./flashcat-crash`).

- [ ] **Step 3: Add the root `overrides` entry**

In root `oh-package.json5`, under `overrides`, add `"@flashcatcloud/crash": "file:./flashcat-crash"` next to the existing rum/trace entries.

- [ ] **Step 4: Minimal `Index.ets`**
```ets
export { FlashcatCrash } from './src/main/ets/FlashcatCrash';
export { CrashConfiguration, CrashConfigurationBuilder } from './src/main/ets/CrashConfiguration';
```

- [ ] **Step 5: Commit**
```bash
git add flashcat-crash build-profile.json5 oh-package.json5
git commit -m "feat(crash): scaffold flashcat-crash module"
```

---

### Task 2: `CrashConfiguration` (builder)

**Files:**
- Create: `flashcat-crash/src/main/ets/CrashConfiguration.ets`

- [ ] **Step 1: Implement the config + builder** (mirror `RumConfiguration` shape)
```ets
/** Configuration for crash reporting. */
export class CrashConfiguration {
  /** Capture native + ArkTS crashes (hiAppEvent APP_CRASH). Default true. */
  readonly trackCrashes: boolean;
  /** Capture app freezes (hiAppEvent APP_FREEZE / watchdog). Default true. */
  readonly trackAppHangs: boolean;

  constructor(trackCrashes: boolean, trackAppHangs: boolean) {
    this.trackCrashes = trackCrashes;
    this.trackAppHangs = trackAppHangs;
  }
}

export class CrashConfigurationBuilder {
  private trackCrashes: boolean = true;
  private trackAppHangs: boolean = true;

  setTrackCrashes(enabled: boolean): CrashConfigurationBuilder {
    this.trackCrashes = enabled;
    return this;
  }

  setTrackAppHangs(enabled: boolean): CrashConfigurationBuilder {
    this.trackAppHangs = enabled;
    return this;
  }

  build(): CrashConfiguration {
    return new CrashConfiguration(this.trackCrashes, this.trackAppHangs);
  }
}
```

- [ ] **Step 2: Commit**
```bash
git add flashcat-crash/src/main/ets/CrashConfiguration.ets
git commit -m "feat(crash): add CrashConfiguration builder"
```

---

### Task 3: `CrashEventMapper` (pure translation) — TDD

This is the testable heart: convert one `hiAppEvent` system-event payload (as a `Record<string, Object>`, the shape `hiAppEvent` delivers in `AppEventInfo.params`) into a bus message for the RUM feature. Pure function, no device APIs.

**Files:**
- Create: `flashcat-crash/src/main/ets/internal/CrashEventMapper.ets`
- Test: `flashcat-crash/src/test/CrashEventMapper.test.ets`
- Modify: `flashcat-crash/src/test/List.test.ets` (register the suite)

**Bus message contract** (consumed by RumFeature in Task 5):
```
{
  type: 'crash_report',
  target: 'rum',
  message: string,        // exception name + first line of reason
  stack: string,          // full raw stack (ArkTS frames and/or native frames)
  source: 'source',       // RumErrorSource value; native vs ArkTS both report as source-level crash
  is_crash: true,
  crash_kind: 'crash' | 'freeze',
  // native symbolication metadata (empty for pure-ArkTS crashes):
  binary_images: string,  // JSON string of [{name, uuid/buildId, arch, load_address}], or ''
  arch: string            // '' when unknown
}
```

- [ ] **Step 1: Write the failing test**
```ets
import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { CrashEventMapper } from '../main/ets/internal/CrashEventMapper';

export default function crashEventMapperTests(): void {
  describe('CrashEventMapper', (): void => {
    it('mapsArkTsCrash', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const params: Record<string, Object> = {
        'crash_type': 'JsError',
        'exception': {
          'name': 'TypeError',
          'message': "Cannot read property 'x' of undefined",
          'stack': 'at foo (entry/src/main/ets/pages/Index.ets:42:13)'
        } as Record<string, Object>
      };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(params);
      expect(ev['type']).assertEqual('crash_report');
      expect(ev['target']).assertEqual('rum');
      expect(ev['is_crash']).assertEqual(true);
      expect(ev['crash_kind']).assertEqual('crash');
      expect((ev['message'] as string).indexOf('TypeError')).assertLarger(-1);
      expect((ev['stack'] as string).indexOf('Index.ets:42')).assertLarger(-1);
    });

    it('mapsNativeCrashWithBinaryImages', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const params: Record<string, Object> = {
        'crash_type': 'NativeCrash',
        'exception': {
          'signal': 11,
          'message': 'SIGSEGV',
          'stack': '#00 pc 00001234 /data/app/libdemo.so'
        } as Record<string, Object>,
        'external_log': ['/data/log/faultlog/cppcrash-1234'] as Object
      };
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash(params);
      expect(ev['crash_kind']).assertEqual('crash');
      expect((ev['stack'] as string).indexOf('libdemo.so')).assertLarger(-1);
    });

    it('mapsFreeze', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const params: Record<string, Object> = {
        'exception': { 'message': 'App freeze: THREAD_BLOCK_6S' } as Record<string, Object>
      };
      const ev: Record<string, Object> = CrashEventMapper.fromAppFreeze(params);
      expect(ev['crash_kind']).assertEqual('freeze');
      expect(ev['is_crash']).assertEqual(true);
    });

    it('toleratesMissingFields', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      const ev: Record<string, Object> = CrashEventMapper.fromAppCrash({});
      expect(ev['type']).assertEqual('crash_report');
      expect(ev['message']).assertEqual('Unknown crash');
      expect(ev['stack']).assertEqual('');
    });
  });
}
```

- [ ] **Step 2: Register the suite in `List.test.ets`**
```ets
import crashEventMapperTests from './CrashEventMapper.test';
export default function testsuite(): void {
  crashEventMapperTests();
}
```

- [ ] **Step 3: Run, expect FAIL** (module not found / class undefined)
Run (env from `docs/HANDOFF.md`): `node ~/Downloads/command-line-tools/hvigor/bin/hvigorw.js test --no-daemon` — expect compile error for missing `CrashEventMapper`.

- [ ] **Step 4: Implement `CrashEventMapper`**
```ets
import { RumErrorSource } from './RumErrorSourceLite';

/**
 * Pure translation of a hiAppEvent system-event payload into a RUM bus message.
 * No device APIs — fully unit-testable. The thin watcher that feeds these params
 * lives in CrashFeature and is verified on device.
 */
export class CrashEventMapper {
  static fromAppCrash(params: Record<string, Object>): Record<string, Object> {
    return CrashEventMapper.build(params, 'crash');
  }

  static fromAppFreeze(params: Record<string, Object>): Record<string, Object> {
    return CrashEventMapper.build(params, 'freeze');
  }

  private static build(params: Record<string, Object>, kind: string): Record<string, Object> {
    const exception: Record<string, Object> = CrashEventMapper.asRecord(params['exception']);
    const name: string = CrashEventMapper.asString(exception['name']);
    const reason: string = CrashEventMapper.asString(exception['message']);
    const stack: string = CrashEventMapper.asString(exception['stack']);
    let message: string = name.length > 0 ? `${name}: ${reason}` : reason;
    if (message.length === 0) {
      message = 'Unknown crash';
    }
    const event: Record<string, Object> = {
      'type': 'crash_report',
      'target': 'rum',
      'message': message,
      'stack': stack,
      'source': RumErrorSource.SOURCE as string,
      'is_crash': true,
      'crash_kind': kind,
      'binary_images': CrashEventMapper.binaryImages(params),
      'arch': CrashEventMapper.asString(params['arch'])
    };
    return event;
  }

  private static binaryImages(params: Record<string, Object>): string {
    const images: Object | undefined = params['binary_images'];
    if (Array.isArray(images)) {
      return JSON.stringify(images);
    }
    return '';
  }

  private static asRecord(value: Object | undefined): Record<string, Object> {
    if (value !== undefined && typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, Object>;
    }
    return {};
  }

  private static asString(value: Object | undefined): string {
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return `${value}`;
    }
    return '';
  }
}
```

`RumErrorSourceLite.ets` — a local string-enum mirror so crash does not depend on the rum module (crash only depends on core). Create alongside:
```ets
/** Local mirror of RUM's error-source string values to avoid a rum→crash dep cycle. */
export enum RumErrorSource {
  SOURCE = 'source'
}
```

- [ ] **Step 5: Run, expect PASS**
Run: `node ~/Downloads/command-line-tools/hvigor/bin/hvigorw.js test --no-daemon` — all 4 cases PASS.

- [ ] **Step 6: Commit**
```bash
git add flashcat-crash/src/main/ets/internal/CrashEventMapper.ets flashcat-crash/src/main/ets/internal/RumErrorSourceLite.ets flashcat-crash/src/test/
git commit -m "feat(crash): pure CrashEventMapper with unit tests"
```

---

### Task 4: `CrashFeature` + `FlashcatCrash.enable` (watcher wiring)

**Files:**
- Create: `flashcat-crash/src/main/ets/internal/CrashFeature.ets`
- Create: `flashcat-crash/src/main/ets/FlashcatCrash.ets`

- [ ] **Step 1: Implement `CrashFeature`** (installs the hiAppEvent watcher; converts → bus)
```ets
import { SdkCore, Feature, FeatureScope, CRASH_FEATURE_NAME, RUM_FEATURE_NAME } from '@flashcatcloud/core';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { CrashConfiguration } from '../CrashConfiguration';
import { CrashEventMapper } from './CrashEventMapper';

const WATCHER_NAME: string = 'flashcat_crash_watcher';

/**
 * Crash feature. Subscribes to hiAppEvent APP_CRASH / APP_FREEZE. hiAppEvent
 * persists the crash and replays it on the NEXT launch, so cross-death durability
 * is handled by the OS. Each delivered event is mapped (pure) and published on the
 * bus to the RUM feature, which writes it as an is_crash error event.
 *
 * The watcher callback runs in a benign context (not the dying process), but is
 * still wrapped so it can never throw.
 */
export class CrashFeature implements Feature {
  readonly name: string = CRASH_FEATURE_NAME;
  private readonly core: SdkCore;
  private readonly configuration: CrashConfiguration;
  private watching: boolean = false;

  constructor(core: SdkCore, configuration: CrashConfiguration) {
    this.core = core;
    this.configuration = configuration;
  }

  onInitialize(): void {
    const names: string[] = [];
    if (this.configuration.trackCrashes) {
      names.push(hiAppEvent.event.APP_CRASH);
    }
    if (this.configuration.trackAppHangs) {
      names.push(hiAppEvent.event.APP_FREEZE);
    }
    if (names.length === 0) {
      return;
    }
    try {
      hiAppEvent.addWatcher({
        name: WATCHER_NAME,
        appEventFilters: [{ domain: hiAppEvent.domain.OS, names: names }],
        onReceive: (domain: string, groups: Array<hiAppEvent.AppEventGroup>) => {
          this.handle(groups);
        }
      });
      this.watching = true;
    } catch (_e) {
      this.watching = false;
    }
  }

  private handle(groups: Array<hiAppEvent.AppEventGroup>): void {
    try {
      const rum: FeatureScope | null = this.core.getFeature(RUM_FEATURE_NAME);
      if (rum === null) {
        return;
      }
      for (const group of groups) {
        const isFreeze: boolean = group.name === hiAppEvent.event.APP_FREEZE;
        for (const info of group.appEventInfos) {
          const params: Record<string, Object> = info.params as Record<string, Object>;
          const ev: Record<string, Object> =
            isFreeze ? CrashEventMapper.fromAppFreeze(params) : CrashEventMapper.fromAppCrash(params);
          rum.sendEvent(ev);
        }
      }
    } catch (_e) {
      // Crash reporting must never crash the app.
    }
  }

  onStop(): void {
    if (this.watching) {
      try {
        hiAppEvent.removeWatcher({ name: WATCHER_NAME });
      } catch (_e) {
        // already removed
      }
      this.watching = false;
    }
  }
}
```

- [ ] **Step 2: Implement `FlashcatCrash.enable`** (mirror `FlashcatRum.enable`)
```ets
import { Flashcat, SdkCore } from '@flashcatcloud/core';
import { CrashConfiguration } from './CrashConfiguration';
import { CrashFeature } from './internal/CrashFeature';

/**
 * Enables crash reporting. Call AFTER `Flashcat.initialize` and AFTER
 * `FlashcatRum.enable` (crash events are reported through the RUM feature).
 *
 * ```ets
 * FlashcatCrash.enable(new CrashConfigurationBuilder().build());
 * ```
 */
export class FlashcatCrash {
  static enable(configuration: CrashConfiguration, sdkCore?: SdkCore): void {
    const core: SdkCore = sdkCore ?? Flashcat.getInstance();
    core.registerFeature(new CrashFeature(core, configuration));
  }
}
```

- [ ] **Step 3: Build the module (HAR)**
Run: `node ~/Downloads/command-line-tools/hvigor/bin/hvigorw.js assembleHar --no-daemon` — expect `flashcat-crash/build/.../flashcat_crash.har` produced, no compile errors.

- [ ] **Step 4: Commit**
```bash
git add flashcat-crash/src/main/ets/FlashcatCrash.ets flashcat-crash/src/main/ets/internal/CrashFeature.ets
git commit -m "feat(crash): CrashFeature hiAppEvent watcher + FlashcatCrash.enable"
```

---

### Task 5: RUM feature consumes `crash_report` bus events — TDD

**Files:**
- Modify: `flashcat-rum/src/main/ets/internal/RumFeature.ets` (add `crash_report` branch in `onReceive`)
- Modify: `flashcat-rum/src/main/ets/internal/monitor/DefaultRumMonitor.ets` (only if a new helper is needed — `reportError` already exists with `isCrash` param)
- Test: `flashcat-rum/src/test/CrashReport.test.ets`
- Modify: `flashcat-rum/src/test/List.test.ets`

- [ ] **Step 1: Write the failing test** — assemble a crash ErrorEvent through the monitor and assert `error.is_crash === true` and source/stack carried.
```ets
import { describe, expect, it, Level, Size, TestType } from '@ohos/hypium';
import { RumEventAssembler } from '../main/ets/internal/assembly/RumEventAssembler';
import { RumErrorSource } from '../main/ets/RumTypes';

export default function crashReportTests(): void {
  describe('RumCrashReport', (): void => {
    it('assemblesCrashErrorEvent', TestType.FUNCTION | Size.SMALLTEST | Level.LEVEL0, (): void => {
      // Use the assembler directly to verify is_crash propagates into the event.
      const event: Record<string, Object> =
        RumEventAssembler.error('TypeError: boom', RumErrorSource.SOURCE, 'at foo (Index.ets:1:1)', true);
      const error: Record<string, Object> = event['error'] as Record<string, Object>;
      expect(error['is_crash']).assertEqual(true);
      expect(error['source']).assertEqual('source');
      expect((error['stack'] as string).indexOf('Index.ets')).assertLarger(-1);
    });
  });
}
```
NOTE: confirm `RumEventAssembler.error(...)` signature against the actual file before finalizing; if it requires a context/view argument, construct the minimal fixture the existing resource/error tests use. Adjust the call to match — do not invent a signature.

- [ ] **Step 2: Register suite + run, expect FAIL**
Add `import crashReportTests from './CrashReport.test'; crashReportTests();` to `List.test.ets`.
Run: `node ~/Downloads/command-line-tools/hvigor/bin/hvigorw.js test --no-daemon`.

- [ ] **Step 3: Add the `crash_report` branch in `RumFeature.onReceive`**
```ets
    } else if (type === 'crash_report') {
      this.onCrashReport(event);
    }
```
and the handler (place near the network handlers):
```ets
  private onCrashReport(event: Record<string, Object>): void {
    const m: DefaultRumMonitor | null = this.monitor;
    if (m === null) {
      return;
    }
    const attributes: Record<string, Object> = {};
    const images: Object | undefined = event['binary_images'];
    if (typeof images === 'string' && images.length > 0) {
      attributes['_dd.crash.binary_images'] = images;
    }
    const arch: Object | undefined = event['arch'];
    if (typeof arch === 'string' && arch.length > 0) {
      attributes['_dd.crash.arch'] = arch;
    }
    m.reportError(
      RumFeature.asString(event['message']),
      RumErrorSource.SOURCE,
      RumFeature.asString(event['stack']),
      true,
      'unhandled',
      attributes);
  }
```

- [ ] **Step 4: Run, expect PASS**
Run: `node ~/Downloads/command-line-tools/hvigor/bin/hvigorw.js test --no-daemon` — crash assembler test PASS, existing suites still PASS.

- [ ] **Step 5: Commit**
```bash
git add flashcat-rum/src/main/ets/internal/RumFeature.ets flashcat-rum/src/test/
git commit -m "feat(rum): consume crash_report bus events as is_crash errors"
```

---

### Task 6: Full build, lint, and Round-1 doc checkpoint

- [ ] **Step 1: Clean assemble all HARs**
Run (env from `docs/HANDOFF.md`):
`node ~/Downloads/command-line-tools/hvigor/bin/hvigorw.js clean assembleHar --no-daemon --stacktrace`
Expected: core, rum, trace, **crash** HARs all produced, exit 0.

- [ ] **Step 2: Run all tests**
`node ~/Downloads/command-line-tools/hvigor/bin/hvigorw.js test --no-daemon --stacktrace` — all suites PASS.

- [ ] **Step 3: Lint**
`codelinter -c code-linter.json5 -f default -e error .` — no errors.

- [ ] **Step 4: Append Round-1 results to the design doc**
Append a "Round 1" subsection under "Round log" in
`docs/superpowers/specs/2026-06-13-harmony-crash-symbolication-design.md`:
what shipped (module list, bus contract `crash_report`, hiAppEvent replay
insight), what was verified locally (assembleHar/test/codelinter green), and
what remains for on-device verification (actual hiAppEvent delivery + native
stack shape). Update `docs/HANDOFF.md` Next step + checklist.

- [ ] **Step 5: Commit**
```bash
git add docs/
git commit -m "docs: round-1 crash module results + handoff"
```

---

## On-device verification (deferred — needs DevEco device/emulator)

- [ ] hiAppEvent watcher actually fires: trigger a native crash and an ArkTS throw; confirm `onReceive` delivers `APP_CRASH` on the **next** launch.
- [ ] Confirm the real `info.params` shape matches `CrashEventMapper` field reads (`exception.name/message/stack`, native `external_log`, arch/binary images). Adjust the mapper to the observed shape if needed.
- [ ] Confirm a `"type":"error"` NDJSON line with `error.is_crash:true` reaches `/api/v2/rum`, force-flushed.
- [ ] APP_FREEZE delivered for a >6s main-thread block.
```
