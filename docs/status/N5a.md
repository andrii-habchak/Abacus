# N5a — Recurring transactions core (lane `wp/N5a-recurring-core`)

Scope: steps 1–3 of `docs/status/N5.md` "Left to do" (repositories, matching, launch sweep).
Spec: `docs/status/N5-spec.md` (R-REC-1…9, 16). No UI.

_Last update: 2026-11-17._

## Step 1 — Repositories: done

- Contracts in the new file `AbacusDomain/Protocols/ScheduledContracts.swift` (granted as
  `Protocols/Scheduled.swift`; renamed because `Model/Scheduled.swift` exists and SwiftPM refuses two
  files of one name in a module): `ScheduledItemRepository`, `ScheduledOccurrenceRepository`,
  `SuggestionDismissalRepository`, `ScheduledMatching` (the rule, injected), `ScheduledImportMatching`,
  `ScheduledMaintenance`, value types `ScheduledProbe`, `ScheduledCandidate`, `ScheduledAssignment`,
  `ScheduledImportMatch`, `ScheduledSweepResult`, errors `ScheduledError`.
- `AbacusStore/Repositories/ScheduledRepository.swift`: `SQLiteScheduledStore` (items CRUD with
  validation, owner pause/resume, delete keeps occurrences; dismissals add/restore) and
  `ScheduledRules` (db-level rules used by the hooks below).
- `AbacusStore/Repositories/ScheduledOccurrenceRepository.swift`: occurrences (mark paid / skip /
  reopen, identity (item, day) guarded in code, synced duplicates collapse on the next write and read
  as one), matching after a manual save, launch sweep, and the `SQLiteImportStore` conformance for the
  import (R-REC-7a).
- Tests: `AbacusStoreTests/ScheduledStoreTests.swift` (R-REC-1, 3, 4, 5, 16).

### Edits outside the owned paths (minimal hooks, please review)

- `AbacusStore/Repositories/AccountRepository.swift`: `save` also refuses a currency change while
  scheduled items exist on the account (`StoreError.currencyLocked`, reused); `setArchived` pauses /
  resumes the account's items; `delete` deletes the account's items (either side of a transfer).
- `AbacusStore/Repositories/TxnRepository.swift` `delete`: `ScheduledRules.reopenOrphans(db)` after
  the delete (an occurrence it paid is expected again).
- `AbacusStore/Repositories/ImportStore.swift` `undo`: the same call after the batch's transactions
  are deleted (undo import un-matches).

## Interpretations (decided without the owner; revisit if wrong)

- **Unlink is durable**: "reopen" of a paid occurrence writes a `suggestionDismissals` row with key
  `unlinked-txn|<txn id>` so automatic matching (save, sweep) never takes that transaction again. No
  schema change needed; `dismissals()` hides these rows. A proper column/table can replace it later
  (orchestrator: consider it for a later migration).
- **Paused period**: resuming an item (owner or unarchive) stores the occurrences of the paused gap that
  are already past the grace period as `skipped`, so they are not reported as missed (spec §4
  "Account unarchived").
- **Missed** rows are only stored for occurrences on or after the day the item was created (spec §4
  "Item starts in the past": older ones do not exist).
- A stored `missed` occurrence can still be paid by a matching transaction (a late statement).
- Matching runs for `active` items only (owner-paused and ended items are not matched).
- An item is `ended` when the last occurrence of a finite series is resolved (paid, skipped or missed),
  and active again if that occurrence is reopened.
- Account delete deletes the items without asking: asking is the UI's job (R-REC-5).
- A paid occurrence whose transaction is gone (`ON DELETE SET NULL`) is deleted, i.e. expected again
  (or missed by the next sweep if past grace).
