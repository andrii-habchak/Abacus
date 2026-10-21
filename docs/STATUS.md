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
| B1 Shell, settings, rates | background agent | `wp/B1-shell` | **merged** 2026-10-21: live AppSession, routing for all sections but Import, editor, Load Sample Data, rates, Settings |
| B3 Transaction list | background agent | `wp/B3-transactions` | **merged** 2026-10-21 on PreviewData; screenshots `docs/status/B3-screens/`; wiring notes in `docs/status/B3.md` |
| B2 Dashboard | background agent | `wp/B2-dashboard` | **merged** 2026-10-21 on PreviewData; screenshots `docs/status/B2-screens/`; wiring notes in `docs/status/B2.md` |
| A6 Import pipeline | background agent | `wp/A6-pipeline` | **merged** 2026-10-21 (real Saldo+PKO pass; decisions in `docs/status/A6.md`) |
| B4 Editor | background agent | `wp/B4-editor` | **merged** 2026-10-21 on PreviewData; screenshots `docs/status/B4-screens/`; wiring notes in `docs/status/B4.md` |
| B5 Management | background agent | `wp/B5-manage` | **merged** 2026-10-21 on PreviewData; screenshots `docs/status/B5-screens/`; wiring notes in `docs/status/B5.md` |
| B6 Import wizard | background agent (own worktree) | `wp/B6-import` | running since 2026-10-21 |

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
- Done on `main`: `Calc.convert` returns 0 for a zero amount without needing a rate (B2 request).
- B2 request (backlog): `TxnQuery` filter for uncategorised transactions, so the Uncategorised slice
  can drill down.

## Getting real data into the app (owner request, 2026-10-21)

1. B1 (scope added): routes Dashboard and Transactions to the live database, starts the rate
   refresher, keeps placeholders for other sections, adds "Load sample data" (seeds PreviewData
   into an empty database).
2. A6 (scope added): headless import entry point with the wizard's defaults.
3. Orchestrator, after both merge: a small command-line importer that loads the owner's real
   Saldo export and PKO statement from `samples/private/` into
   `~/Library/Application Support/Abacus/abacus.sqlite`, then checks balances.
- 2026-10-21: `abacus-import` tool (AbacusKit executable) added; the owner's real Saldo export is
  imported into the app database: 3,888 transactions, 43 accounts (10 archived), 33 categories,
  280 unpaired halves under "Uncategorised"; all 24 account balances equal the export's.
- 2026-10-21: real PKO PLN statement imported into "PKO private" (owner: PLN → "PKO private",
  USD → "PKO private $", EUR → "PKO Euro", remembered per currency). A "Balance correction" income
  of the gap on 21 Sep aligns Saldo's stale balance with the bank's opening balance; the account
  now equals the bank's latest booked balance with pending holds counted as spent. 1 currency
  exchange half is under "Uncategorised" for review.
- Done on `main`: `TxnRepository.transaction(_:)` (default implementation for fakes).
- Done: one rule matcher (AbacusImport `RuleMatcher`, case/diacritic/whitespace folding) used by imports,
  the editor suggestion and the rules tester. Remaining B5 requests:
  Features vs A6 `RuleMatcher` in AbacusImport — consolidate on A6's); optional protocol
  `balances(asOf:)` / per-category usage counts for 20k-transaction performance; R-CAT-4 default
  categories on first launch still open.
- Fixed 2026-10-21: the synced app folder (D23) had never been applied — screens merged before
  were not compiled into the app until `cd15c07`+1; now `project.yml` uses `type: syncedFolder`
  and the app builds with all screens.
- B1 incident (reported by the lane): a stale screenshot script launched a debug build on the
  real database without writing anything; verified afterwards — counts unchanged, no rate rows.
- Real-data check without screenshots: `RealDataAppSessionTests` imports both real exports into
  memory and loads every screen through `AppSession.live` (counts/timings only): all load, the
  dashboard in ~0.6 s, the list in ~0.15 s. Screenshots of real data are not taken (privacy).
- B1 requests (deferred): `SettingKey.lastBackupExport` (now in UserDefaults); "Change…" data
  folder needs a store-side move/reopen; editor should call `ensureRates(for:)` for old days.
- CI on GitHub has never run: every job stops with "account is locked due to a billing issue"
  (GitHub Actions billing on the owner's account; macOS runners on a private repo use paid
  minutes). Local `swift test` and app builds are the gate until the owner resolves billing or
  decides on CI (owner decision, Q25).
