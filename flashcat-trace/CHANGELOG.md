# Changelog

## Unreleased

- `FlashcatTrace.startTracedResource(url, method, injectTrace?)` +
  `stopTracedResource` / `failTracedResource`: report a request as a RUM
  resource from any network stack the SDK cannot instrument itself — axios, a
  custom client, a WebSocket handshake. Returns the `traceparent` /
  `tracestate` to send, with consent and first-party gating, sampled-only trace
  correlation and the decimal `_dd.span_id` encoding all handled inside the SDK.
  Requires `setTrackNetworkRequests(true)`, like every other network path.
- `FlashcatHttp` now builds on the same entry point instead of duplicating the
  injection and resource-lifecycle logic.

## 0.3.2

- Version bump to keep the SDK packages in lockstep.

## 0.3.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/core`
  0.3.1: the consent value passed at initialization is authoritative again).

## 0.3.0

- `_dd.span_id` emitted as unsigned decimal (RUM↔APM correlation fixed).
- Trace ids attached to RUM resources only for SAMPLED traces; rcp interceptor
  honors `firstPartyHosts`; `getHeaders(url?)` applies the first-party gate;
  IPv6 literals parsed correctly; dead-core guard after stop().

## 0.2.0

- Version bump to keep the SDK packages in lockstep.

## 0.1.3

- Maintenance release; version aligned across the FlashCat HarmonyOS SDK packages.

## 0.1.2

- Put the `dd=` vendor entry first in the W3C `tracestate` header (upstream convention).

## 0.1.0

- Initial HarmonyOS trace propagation release.
