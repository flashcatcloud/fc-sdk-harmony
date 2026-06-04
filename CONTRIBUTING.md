# Contributing to fc-sdk-harmony

## Prerequisites

- **DevEco Studio** (HarmonyOS NEXT / API 12+ SDK) and the bundled `hvigorw` build tool.
- **ohpm** (OpenHarmony Package Manager), configured for the public registry
  `https://ohpm.openharmony.cn/` (plus the FlashCat publish registry when releasing).

> This is a standalone git repo (the SDK workspace is *not* a single git root). `cd` into this
> directory and run `git status` here before committing. Do not assume the parent is a git root.

## Project shape

A multi-module HarmonyOS library project. Each `flashcat-*/` is a **HAR** module published to ohpm
under `@flashcatcloud/*`. New feature modules are added to the root `build-profile.json5` `modules`
array and given their own `oh-package.json5` / `build-profile.json5` / `hvigorfile.ts` / `Index.ets`.

This SDK is **not a fork** — use clean `flashcat-*` / `Flashcat*` naming (Datadog has no HarmonyOS
SDK to track). Keep events conformant to the shared `rum-events-format` schema so fc-rum ingest stays
uniform across platforms.

## Build / lint

```bash
ohpm install
hvigorw assembleHar      # build all HAR modules
hvigorw codeLinter       # ArkTS lint (config: code-linter.json5)
```

## Conventions

- **Edit `src`, not build output** (`build/`, `*.har`, generated sourcemaps).
- **Public API surface** lives in each module's `Index.ets` — anything else is internal.
- **High-risk surface** (public API, config, event/schema shape, intake endpoints, sampling, session
  & lifecycle behavior) must ship with tests.
- **Intake contract:** events POST to fc-rum as **NDJSON with `Content-Type: text/plain`**.
- **License headers** (Apache-2.0) on source files; keep `LICENSE` / `NOTICE` intact.
- **Don't commit, publish, or bump versions** unless explicitly asked.

## Tests

Unit tests use **@ohos/hypium** (+ **@ohos/hamock** for mocks), under each module's
`src/test` / `src/ohosTest`. Run via DevEco Studio or `hvigorw test`.

## Backend

The ingest server is **fc-rum** at `~/workspace/flashcat/duty/server/fc-rum` (outside this workspace).
For end-to-end crash/symbolication work see `docs/DESIGN.md` §4.
