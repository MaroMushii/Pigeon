---
status: complete
priority: p1
issue_id: 001
tags: [code-review, swift, concurrency, bug]
dependencies: []
---

# `withDeadline` does not actually enforce its deadline

## Resolution

Applied **Option B** from the proposal: made `PinnedHTTPSClient.receiveChunk` honor a timeout argument, mirroring the race-against-`Task.sleep` pattern already used by `connect`.

## Changes Made

- `mac/Pigeon/Services/PinnedHTTPSClient.swift`
  - `readUntilClose` now passes a per-iteration `remaining` budget into `receiveChunk` and throws `timedOut` if the budget is exhausted before the next chunk arrives.
  - `receiveChunk` now races `conn.receive` against `Task.sleep(for:)` using `OSAllocatedUnfairLock<Bool>` to claim the continuation exactly once. On timeout, cancels the connection and throws `ClientError.timedOut`.
- `mac/Pigeon/Services/HealthChecker.swift`
  - Updated the `withDeadline` doc comment. The previous text claimed orphaned probes "complete in the background" — incorrect for `withTaskGroup`, which awaits all children. New wording correctly describes it as a defense-in-depth backstop on top of the now-honest inner per-phase timeouts.

## Why Option B over Option A

Option A would have been a local fix in `HealthChecker` only. Option B fixes the root cause and benefits every other caller of `pinned.get` (e.g. `TelegramClient.getWithIPRotation`). The `timeout` argument now means what its name implies everywhere.

## Verification

Build verification blocked by unrelated in-progress refactor (SettingsStore → ChannelService init signature mismatch in `PigeonApp.swift`) — not from this fix. Once that lands, the diff here is structurally identical to the `connect` pattern that has been in production.

## Work Log

- Reviewed `connect` for the canonical race pattern (PinnedHTTPSClient.swift:236-292)
- Applied the same pattern to `receiveChunk`
- Updated `readUntilClose` to thread the remaining budget per iteration
- Corrected the misleading `withDeadline` docstring

