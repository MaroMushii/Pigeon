---
status: complete
priority: p2
issue_id: 003
tags: [code-review, swift, concurrency, refactor]
dependencies: [001]
---

# `runChecks` used unstructured Tasks; lost cancellation chain

## Resolution

Replaced the manual `Task { @MainActor in ... }` spawning + bookkeeping with a single `withTaskGroup`. Cancellation now propagates from SwiftUI's `.task { runChecks() }` down into every probe.

## Changes Made

- `mac/Pigeon/Views/HealthCheck/HealthCheckView.swift:57-79` — replaced unstructured Tasks with `withTaskGroup`. Added `defer { isChecking = false }` so the flag is reset even if the group throws or is cancelled. Per-row updates still happen as soon as each probe resolves (`for await result in group { replace(result) }`).

## Why this matters now

This todo was blocked on #001 because cancellation only delivers value if the inner I/O actually honors it. With the `receiveChunk` fix in #001, `pinned.get` now bails out within its `timeout` budget, so cancellation through the structured chain is meaningful.

## Work Log

- Confirmed `HealthCheckView` is `@MainActor`-isolated by virtue of being a SwiftUI `View`, so `replace` calls inside `for await` need no extra annotations.
- `defer { isChecking = false }` makes the cleanup robust against future failure paths.
- Removed the now-unnecessary explicit `@MainActor in` annotations and per-task `await .value` waits.
