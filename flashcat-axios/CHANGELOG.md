# Changelog

## 0.7.3

- The axios interceptors never fail or alter the host's request: telemetry
  failures are contained and the config, response and rejection pass through
  unchanged. In-flight tracking is capped at 256 requests per process.
- Trace headers follow `@flashcatcloud/trace` 0.7.3: none unless first-party
  hosts are configured.

## 0.7.2

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/crash`
  0.7.2: `REPORT_AND_CONTINUE` crash policy).

## 0.7.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.7.1: remote configuration survives app upgrades).

## 0.7.0

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.7.0: error-session capture).

## 0.6.0

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.6.0: remote configuration).

## 0.5.1

- Version bump to keep the SDK packages in lockstep (see `@flashcatcloud/rum`
  0.5.1: app freezes are now categorized as ANR).

## 0.5.0

- Version bump to keep the SDK packages in lockstep.

## 0.4.0

- Initial release. `trackAxios(instance)` reports every request made through an
  `@ohos/axios` instance as a RUM resource and attaches the distributed-trace
  headers, replacing the interceptor code applications previously had to carry
  themselves.
