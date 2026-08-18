# Changelog

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
