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

## Step 2 — Matching: done

- `ScheduledMatch` in `AbacusImport/Dedupe/Matching.swift`: R-REC-6 composed of
  `FuzzyDuplicate.dayWindow`, `PendingSettlement.amountMatches` (per-item tolerance, same formula),
  `DescriptionSimilarity`, `Flow`; `assign` gives one transaction per occurrence and back, nearest day,
  then nearest amount, then equal description, then the older item. `ScheduledMatch.rule` is the
  `ScheduledMatching` value the store takes (the store cannot import `AbacusImport`).
- Import (R-REC-7a): `RowAnalyzer.matchScheduled` (rows that create a transaction, not exact/duplicate/
  settle/debt-leg/review rows) → `PreviewRow.scheduledMatch` (`ScheduledRowMatch`: item id, item
  description, type, expected day = the badge "Matches scheduled: <item> · <day>") and
  `ImportPreview.scheduledMatchCount`. Nothing is written before the commit. After
  `store.commit`, `ImportPipeline.commit` calls `recordScheduledMatches` (the batch's transactions found
  by the rows' fingerprints) — a separate write after the import transaction, because `ImportCommit` is
  a shared contract; a failure there leaves the import and the launch sweep matches later.
- Manual save/edit (R-REC-7b): `SQLiteScheduledStore.matchTransaction(_:matcher:)` — the editor calls
  it after a save (UI wiring not done, N5b). A linked transaction keeps its link; the actual day and
  amount are refreshed.
- Undo import un-matches (hook in `ImportStore.undo`).
- Tests: `AbacusImportTests/ScheduledMatchTests.swift` (R-REC-6 rule table; R-REC-7 preview/commit/undo,
  manual save; R-REC-3).

## Step 3 — Launch sweep: done

- `SQLiteScheduledStore.sweep(today:matcher:)`, one write transaction, idempotent: (1) pause/resume by
  archive state (covers archive changes that bypass the repository, e.g. sync), (2) paid occurrences whose
  transaction is gone return to expected, (3) match unlinked transactions from
  `today − grace − 31 days` to `today + 3`, (4) store `missed` (`ScheduledOccurrences.missed`, grace from
  `SettingKey.scheduledGraceDays`, default 14), (5) end finished items. Returns counts.
- No code path creates or changes a `Txn` (R-REC-3 test asserts the transactions are identical).

## For the orchestrator / next lanes

- **Wiring (not done, UI/app scope):** call `SQLiteScheduledStore(database:calendar:).sweep(today:
  matcher: ScheduledMatch.rule)` once at launch (before the N5c snapshot, R-REC-17), and
  `matchTransaction(id, matcher: ScheduledMatch.rule)` after the editor saves a transaction.
- Not done: a settled PKO hold refreshing its occurrence's actual amount/day (the link follows the
  transaction because the hold is updated in place; the actuals refresh at the next `matchTransaction`
  of that transaction). "Link existing…" candidate list (R-REC-4) is left to N5b (it can use
  `ScheduledMatch.matches` with a probe per transaction).
- The new protocol file is `Protocols/ScheduledContracts.swift` (name clash, see step 1).

## Gate

- `swift test` with `ABACUS_SAMPLES`: 1292 tests green (Domain 181, FX 40, Import 293, Features 618,
  MCP 46, Store 114). New: 11 store + 10 import tests.
- macOS app build: BUILD SUCCEEDED.

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
- Matching runs for active and ended items (an ended item's earlier occurrences stay open to a late
  transaction and still become missed); paused items are not matched.
- An item is `ended` when the last occurrence of a finite series is resolved (paid, skipped or missed),
  and active again if that occurrence is reopened.
- Account delete deletes the items without asking: asking is the UI's job (R-REC-5).
- A paid occurrence whose transaction is gone (`ON DELETE SET NULL`) is deleted, i.e. expected again
  (or missed by the next sweep if past grace).
