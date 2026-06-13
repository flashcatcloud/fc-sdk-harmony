# HarmonyOS SDK — Security & Stability Review (Round 6)

Scope: the crash module, the hvigor upload plugin, and the fc-rum HarmonyOS
symbolicator added in Rounds 1–5. Findings are either ✅ (verified safe) or list
the concrete fix applied.

## Consent & privacy

- ✅ **Crash events are consent-gated.** Crash/freeze events flow
  `CrashFeature → bus → RumFeature.reportError → …writer.write`, and the core's
  `PersistenceEventWriter` checks tracking consent on every write: `NOT_GRANTED`
  drops, `PENDING` buffers in the separate `pending/` dir, `GRANTED` persists.
  No separate crash-write path bypasses consent.
- ✅ **No credentials in events.** `clientToken` was already removed from the
  context/`getContext` (credential hygiene); crash events carry only
  message/stack/binary_images/arch — no token, no API key.
- ✅ **No PII added by the crash path.** The mapper copies only the hiAppEvent
  fault fields; it introduces no device identifiers beyond the existing context.

## Crash path stability (must never crash the host)

- ✅ `CrashFeature.handle` wraps the whole hiAppEvent callback in try/catch.
- ✅ `CrashEventMapper` is pure and null-safe (`asString`/`asRecord` tolerate
  missing/!typed fields; `toleratesMissingFields` test).
- ✅ Re-entrancy: the live ArkTS hook in RUM keeps its `handlingError` guard; the
  crash module's hiAppEvent path runs on the next launch (not the dying process).
- ✅ **Payload caps** (Round 5) bound message/stack/binary_images so an oversized
  fault can't produce a >1 MiB intake body or bloat on-disk batches.

## Untrusted-input hardening (fix applied this round)

- **ELF parser (`hvigor-plugin/src/elf.ts`)** reads attacker-influenceable `.so`
  files. Hardened: the whole parse is wrapped so it returns `null` instead of
  throwing; the section table is bounds-checked against EOF; note iteration is
  clamped to the section/file length. Covered by a 200-case fuzz test
  (`never throws on malformed/fuzzed ELF-ish input`).
- **Stack parser (`logic/stack/parse_harmony_shared.go`)** processes raw crash
  strings. Hardened: lines over 8 KB are skipped before regex matching (bounds
  worst-case cost). `FuzzParseHarmony` runs clean (32k execs/5s, no panic); seed
  corpus runs in `go test`.

## Backend access control

- ✅ **Account-scoped storage.** Symbol objects are written with
  `PutObject(uint64(accountID), …)` (account segment prepended) and every lookup
  (`FindOne`, `FindByCondition`) filters by `accountID`. Two accounts cannot read
  or overwrite each other's symbols — the Android-native key already includes
  `accountID` for exactly this reason, and the HarmonyOS path reuses it.
- ✅ **Auth.** `/sourcemap/upload` is behind `APIKeyAuth()` (DD-API-KEY → account).
  The plugin sends the key only in that header and never logs it (only a
  "not set" warning). Upload failures log the server response body, not the key.
- ✅ **Upload size limits.** HarmonyOS uploads are capped at the Android limit
  (500 MB) with early Content-Length rejection + a decompression bomb guard
  (shared `Upload` entrypoint).

## Residual risks (tracked, not code-fixable here)

- The real on-device `hiAppEvent` `params` shape is assumed from docs; a mismatch
  is a correctness (not security) risk, gated by `docs/E2E-RUNBOOK.md` step 4.
- ArkTS `sourceMaps.map` key format vs. obfuscated frame `File` — correctness,
  gated by the runbook.
