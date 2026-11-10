# Changelog

## 0.7.10

- No changes; released together with `@flashcatcloud/rum` 0.7.10.

## 0.7.9

- No changes; released together with `@flashcatcloud/rum` 0.7.9.

## 0.7.8

- No changes; released together with `@flashcatcloud/rum` 0.7.8.

## 0.7.7

- A request that fails before any response (connection refused, DNS
  failure, timeout) is reported as a network error. @ohos/axios rejects
  such a failure with its internal http request object in
  `error.response`, so it was reported as a completed resource with status
  0 and no error. Only a response with an HTTP status now counts as one.

## 0.7.6

- No changes; released together with `@flashcatcloud/rum` 0.7.6.

## 0.7.5

- `trackAxios` ignores something that is not an axios instance instead of
  throwing, and registers its response interceptor first, so a registration
  that fails part-way leaves no request interceptor behind.

## 0.7.4

- No changes; released with the other packages.

## 0.7.3

- The axios interceptors never fail or alter the host's request: telemetry
  failures are contained and the config, response and rejection pass through
  unchanged. In-flight tracking is capped at 256 requests per process.
- Resource size comes from the `Content-Length` header (else a string or
  ArrayBuffer body's length); a parsed JSON body is no longer serialized
  again on the response path just to be measured.
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
