# Status

_Last updated: 2026-10-30 (orchestrator)_

## Now

_Updated 2026-10-30 (orchestrator)._ **1.2.2 is released** (build 5, tag `v1.2.2`, GitHub release with the DMG, 2026-10-30): C15 rule
conditions (starts with / equals) and C16 PKO hold sign fix on top of 1.2.1.
No database changes. Released so far: `v1.0.0`, `v1.2.1` (2026-10-27), `v1.2.2`.

_Updated 2026-10-27 (orchestrator)._ **1.2.1** (version 1.2.1, build 4) was released as `v1.2.1`
on 2026-10-27.
1.1.0 and 1.2.0 were test builds and are folded into 1.2.1 (see CHANGELOG).

- Done since v1.0.0 (all merged, gate green, 695 tests incl. real-data tests):
  - Phase 3c, owner review of 1.0.0: C3 import window height, C4 navigation, C5 colours,
    C6 budget currency, C7 rules.
  - Phase 3d, owner review of 1.1.0: C8 budget total, C9 rules rollback, C10 categories,
    C11 transactions/events, C12 account groups, C13 dashboard widgets, C14 debts.
  - Phase 3e, stability: S1 crashes and speed, S2 native outline lists and sheet editors,
    S3 budget Save states and the rules tester removed.
- Database: migrations v4–v11 run on the owner's real database at the first launch of 1.1.0+.
  The debts conversion (v10) was checked on the real Saldo export in memory (balances and net
  worth unchanged). The owner backs up `abacus.sqlite` before installing.
- README screenshots retaken 2026-10-28 with real window captures (ScreenCaptureKit, R2), EUR,
  full dashboard; sample data only.
- `build.noindex/` is the build output folder (Spotlight skips it); the old `build/` can be deleted.

**Waiting on the owner**: feedback on 1.2.2; confirm the lane interpretations in `docs/status/C6.md` to
`C16.md` and `S1.md`–`S3.md`. Open import ideas offered 2026-10-30, not started: multi-file import,
"Uncategorised" card in the import wizard, PKO exchange fee line, IBAN hint on unpaired halves,
moving import mappings when a category is merged or deleted.

## Done

- Repo `andrii-habchak/Abacus`; agent guide `AGENTS.md`.
- Research (comparable apps, multi-currency, FX sources, persistence) → TA + D5–D8.
- Saldo and PKO exports analysed → `docs/import/`. Real files in git-ignored `samples/private/`.
- TA v1.2 (all questions closed; prototype-review changes), decisions D1–D20, `PLAN.md`.
- P0 Foundation (`docs/status/P0.md`).
- D1 Prototypes: all six groups approved; sources + decisions in `docs/design/`.

## Next

1. Owner tests 1.2.2; fix what they report on a lane, rebuild the DMG, release as the next patch.
2. Deferred, only on request: merge the "card" and "bank account" kinds (they behave the same);
   SQL aggregates for balances/usage counts beyond ~20k transactions (S1); combine the save
   cascade's per-screen reloads (S1).

The hand-off for a new orchestrator session is `docs/NEXT.md` (`scripts/next-session.sh` prints
and copies it).

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
| B6 Import wizard | background agent | `wp/B6-import` | **merged and wired** 2026-10-21; screenshots `docs/status/B6-screens/` |
| C1 List filters | background agent | `wp/C1-filters` | **merged** 2026-10-22 |
| C2 Settings, data, defaults | background agent | `wp/C2-settings` | **merged** 2026-10-22 |
| R1 Release prep | background agent | `wp/R1-release` | **merged** 2026-10-22 (icon, 1.0.0, `scripts/build-dmg.sh`, README, CHANGELOG) |
| C3 Import window height | background agent | `wp/C3-import-height` | **merged** 2026-10-27 |
| C4 Navigation | background agent | `wp/C4-navigation` | **merged** 2026-10-27 (click-only donut drill-down, budget edit button, currency switch per section) |
| C5 Colours | background agent | `wp/C5-colours` | **merged** 2026-10-27 (palette, random + manual colours, migration v4 fills uncoloured/grey rows once; notes `docs/status/C5.md`) |
| C6 Budget currency | background agent | `wp/C6-budget-currency` | **merged** 2026-10-27 (migration v5; interpretations to confirm in `docs/status/C6.md`) |
| C11 Transactions/events | background agent | `wp/C11-transactions-events` | **merged** 2026-10-27 (event list shows all dates; notes `docs/status/C11.md`) |
| C9 Rules | background agent | `wp/C9-rules` | **merged** 2026-10-27 (apply fix, rollback via migration v8; interpretations in `docs/status/C9.md`) |
| C8 Budget | background agent | `wp/C8-budget` | **merged** 2026-10-27 (widget showed the saved limits; the editor lost unsaved edits — fixed; interpretations in `docs/status/C8.md`) |
| C10 Categories | background agent | `wp/C10-categories` | **merged** 2026-10-27 (built-in Uncategorised, one colour mapping, migration v9; interpretations in `docs/status/C10.md`) |
| C13 Dashboard | background agent | `wp/C13-dashboard` | **merged** 2026-10-27 (income donut, income vs expenses, widget reorder; Debts slot `DashboardView(debts:)`; notes `docs/status/C13.md`) |
| C12 Accounts | background agent | `wp/C12-accounts` | **merged** 2026-10-27 (account groups via migration v11, grouped pickers, net worth hierarchy; interpretations in `docs/status/C12.md`) |
| S3 Budget/rules polish | background agent | `wp/S3-polish` | **merged** 2026-10-27 (Save button states, rules tester removed; notes `docs/status/S3.md`) |
| C15 Rule conditions | background agent | `wp/C15-rule-match` | **merged** 2026-10-30 (Description starts with; "exactly" shown as Description equals; no migration; notes `docs/status/C15.md`) |
| C16 PKO hold sign | background agent | `wp/C16-pending-sign` | **merged** 2026-10-30 (holds always expenses; settling repairs a wrong-sign hold; owner DB checked: nothing to repair; notes `docs/status/C16.md`) |
| S2 Lists | background agent | `wp/S2-lists` | **merged** 2026-10-27 (NSOutlineView lists, sheet editors, split New account; real mouse drag not tested; notes `docs/status/S2.md`) |
| S1 Stability | background agent | `wp/S1-stability` | **merged** 2026-10-27 (debts binding crash reproduced and fixed, safe bindings, Day/Month speed-up, soak + hang watch tools; timings in `docs/status/S1.md`) |
| C14 Debts | background agent | `wp/C14-debts` | **merged** 2026-10-27 (debts separate from accounts, migration v10 converts debt accounts — real-data invariants hold; follow-up: dashboard opens scrolled when Debts is first; interpretations in `docs/status/C14.md`) |
| C7 Rules | background agent | `wp/C7-rules` | **merged** 2026-10-27 (migration v6 rebuilds `categoryRules`; interpretations to confirm in `docs/status/C7.md`) |

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
  minutes). Owner: use local builds, ignore GitHub CI (D37) — workflow made manual-only.
- B6 notes: needs-review rows start undecided with a "Use suggestions (N)" button (the pipeline
  refuses undecided rows); changing the PKO target account rebuilds the preview; a file with
  nothing new disables Import. Deferred: `TxnQuery` filter by import batch (so "Show
  transactions" opens only that batch); editing a learned rule inside the preview.
- Contracts on `main` for Phase 3 lanes: `TxnQuery.includeUncategorised`, `TxnQuery.importBatchIDs`,
  `SettingKey.lastBackupExport`.

## Open items (2026-10-27)

- ~~Import window height~~ → fixed in C3.
- ~~Release v1.0.0~~ → tagged and pushed 2026-10-27.
- ~~1.1.0 / 1.2.0 test builds~~ → superseded by 1.2.1.
- **1.2.1**: owner testing; tag after the OK. Known: debug-build main-thread pauses of
  120–600 ms around sheet open/close (AppKit animation, S1); real mouse drag and drop on the new
  outline lists not yet tried by anyone but the owner (no Accessibility permission for
  synthetic events here).
- **Owner checks**: lane interpretations (C6–C14, S1–S3 status notes); "Uncategorised" rows to
  review; C2 choice D40 (data folder move deletes the old file after a verified copy).
- **Deferred, small**: an open editor doesn't pick up rates fetched by other screens until its
  own request returns (C2); card vs bank account merge; very-large-data SQL aggregates.

Debug tools for checks (DEBUG builds, scratch databases only): `-AbacusLoadLargeSampleData YES`,
`-AbacusSoak YES`, `-AbacusHangWatch YES`, `-AbacusOpenSheet …`, `-AbacusDashboardScrollTo …`,
`-AbacusBudgetDemo edited|saved`, `-AbacusWindowWidth/-AbacusWindowHeight` (see the S1, S2, S3,
C11, C13, C14 status notes).

## How to check the UI safely (never on the owner's real data)

The app reads launch options before opening a database (C2): `-AbacusDatabasePath <tmp file>`,
`-AbacusLoadSampleData YES`, `-AbacusPreviewData YES`, `-AbacusSection <section>`,
`-AbacusOpenSettings general|rates|data`, `-AbacusDark YES`, `-AbacusImportFile <csv>` (DEBUG:
opens Import's review step on that file), snapshot `-AbacusSnapshotDir <dir>
-AbacusSnapshotName <name> [-AbacusSnapshotDelay <s>]` (`App/macOS/Shell/WindowSnapshot.swift`).
Also set `CFFIXED_USER_HOME=<scratch dir>` so saved window sizes and preferences don't touch the
owner's. The terminal has no Screen Recording permission; use the in-app snapshot. Never take
screenshots of the real database.
The snapshot captures the app's own windows with ScreenCaptureKit (no permission needed; real glass and chrome), `-AbacusDisplayCurrency EUR` switches currency, `-AbacusSnapshotFullPage YES` grows the window to the whole page (R2).
