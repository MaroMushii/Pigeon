---
status: complete
priority: p3
issue_id: 004
tags: [code-review, swift, refactor, dry]
dependencies: []
---

# Duplicate `EndpointResult` construction

## Resolution

Consolidated three duplicate construction sites into two static factories on `EndpointResult` itself. Originally the todo only flagged the proxy duplication, but the same shape applied to mirror, so both got the treatment.

## Changes Made

- `mac/Pigeon/Services/HealthChecker.swift`
  - Added `EndpointResult.mirror(baseURL:)` and `EndpointResult.proxy(ip:)` static factories.
  - `EndpointResult.allPending(mirrorBaseURL:)` reduced to a one-liner using `map(EndpointResult.proxy(ip:))`.
  - Removed the redundant `mirrorTemplate` and `proxyTemplate` private helpers from `HealthChecker`. Call sites in `checkMirror`, `checkProxy`, `runMirror`, and `runProxy` now use the static factories directly.
  - `runProxy(ip:template:)` collapsed to `runProxy(ip:)` since the template is trivially derivable from the IP — one fewer parameter to pass through.

## Work Log

- Pattern: `EndpointResult.proxy(ip:)` is callable as a key-path-style argument to `map`, which makes `allPending` very tight.
- Build verified passing.
