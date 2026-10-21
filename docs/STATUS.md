# Status

_Last updated: 2026-10-21 (orchestrator)_

## Now

**P0 Foundation** and **D1 Prototypes** done (all six screen groups approved, `docs/design/`).
**Wave 2 running**: lanes A5 Store, A3 Saldo parser, A2 FX, A4 PKO parser — one session and
branch each (table below). A1 Calculators is the filler for the first lane that finishes.

## Done

- Repo `andrii-habchak/Abacus`; agent guide `AGENTS.md`.
- Research (comparable apps, multi-currency, FX sources, persistence) → TA + D5–D8.
- Saldo and PKO exports analysed → `docs/import/`. Real files in git-ignored `samples/private/`.
- TA v1.2 (all questions closed; prototype-review changes), decisions D1–D20, `PLAN.md`.
- P0 Foundation (`docs/status/P0.md`).
- D1 Prototypes: all six groups approved; sources + decisions in `docs/design/`.

## Next

1. Review and merge Wave 2 branches as they finish; start A1 when a slot frees up.
2. Wave 3: A6 Import pipeline (after A5) and UI lanes B1–B3 on PreviewData.

## In flight

| WP | Lane / session | Branch | State |
|----|----------------|--------|-------|
| A5 Store | background agent | `wp/A5-store` | **merged** 2026-10-21 (all repositories, list/report queries, import commit/undo, backup; 20k list query 78 ms optimised) |
| A3 Saldo parser | background agent | `wp/A3-saldo` | **merged** 2026-10-21 (real export: 964 transfers paired, all 24 account balances reproduced) |
| A2 FX | background agent | `wp/A2-fx` | **merged** 2026-10-21 (Frankfurter/NBU + fallback, RateTable converter, RateRefresher) |
| A4 PKO parser | background agent | `wp/A4-pko` | **merged** 2026-10-21 (79/79 real rows parse) |
| A1 Calculators | background agent | `wp/A1-calc` | **merged** 2026-10-21 (balances, net worth + series, reporting, budget, events) |
| B1 Shell, settings, rates | background agent (own worktree) | `wp/B1-shell` | running since 2026-10-21 (on PreviewData) |
| B3 Transaction list | background agent (own worktree) | `wp/B3-transactions` | running since 2026-10-21 (on PreviewData) |
| B2 Dashboard | background agent (own worktree) | `wp/B2-dashboard` | running since 2026-10-21 (on PreviewData + Calc) |
| A6 Import pipeline | background agent (own worktree) | `wp/A6-pipeline` | running since 2026-10-21 |

## Contract-change requests (orchestrator queue)

- ~~A4: currency minor-unit helper~~ → done: `CurrencyDigits` in `Money.swift`.
- A4 → A6: normalise `Account.iban` (no spaces, no `PL`) before comparing with `counterpartyIBAN`;
  ATM rows arrive as `.transfer` to external account "Cash", currency exchange as `.transferHalf`.
- Contract change on `main` (2026-10-21): `Txn.bookedDay` (migration "v2: txns.bookedDay") and
  `NormalizedRow.bookedDay`. Running lanes (A5, A3, A2, A1) rebase onto `main` before merge; A5
  must include the column in backup/restore.
- A3 request "refund flag on NormalizedLine" → **not added**; convention instead (D22): an attached
  record of kind `.income` in an **expense** category is a refund line. A1 (calculators) and A6
  (pipeline) honour it.
- A3: switch its local minor-units table to `CurrencyDigits` when next touched (low priority).
- `project.yml`: app sources are a synced folder — UI lanes add files under `App/macOS/` without
  regenerating or committing the `.xcodeproj`.
- A2 → A5: `RateStore.save` must upsert by primary key (the refresher reuses ids); the whole
  cache is loaded with `rates(from: 1900-01-01, to: 9999-12-31)` (sent to A5).
- A2 → app wiring (orchestrator, after B1): `RateRefresher.start()` on launch, `runDailySchedule()`
  in a task, `ensureRates(for:)` per screen, `refreshNow()` for Refresh / Try again, auto flag from
  `SettingKey.ratesAutoRefresh`.
- A5 requests (optional, deferred): fold `StoreError.currencyLocked/.invalidParent` into
  `RepositoryError`; add `list(matching:)` (totals) and `transaction(_:)` to the `TxnRepository`
  protocol if view models need them through the protocol (today on `SQLiteTxnRepository`).
- Done on `main`: `AbacusImportTests` depends on `AbacusStore` (pipeline integration tests).
- Done on `main`: migration v3 `importBatchID` on accounts, categories, events; undo removes the
  batch's created entities when unused (D28).
