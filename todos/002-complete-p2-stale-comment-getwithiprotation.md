---
status: complete
priority: p2
issue_id: 002
tags: [code-review, swift, comment-rot]
dependencies: []
---

# Stale comment referenced `getWithIPRotation`

## Resolution

Rewrote the `proxyPerIPTimeout` doc comment in `mac/Pigeon/Services/HealthChecker.swift` to reference `pinned.get` (the actual call site) and explain the relationship to `probeDeadline`.

## Changes Made

- `mac/Pigeon/Services/HealthChecker.swift:47-51` — comment text updated, no code change.

## Work Log

- Confirmed the only call site is `runProxy` at HealthChecker.swift, calling `pinned.get(ip:..., timeout: Self.proxyPerIPTimeout)` directly.
