# N5c — Forecast snapshots and forecast-vs-actual maths (lane `wp/N5c-forecast-data`)

Scope: steps 4 and 5 of `docs/status/N5.md` (spec `docs/status/N5-spec.md`, R-REC-13…20).
No UI, no schema change (v18 tables used as they are).

_Last update: 2026-11-17._

## Done

### Step 4 — snapshots (R-REC-17, R-REC-18)

- Contract `AbacusDomain/Protocols/ForecastSnapshots.swift` (new file): `ForecastSnapshotRepository`
  (`takeIfNeeded(today:rates:debts:)`, `prune(today:)`, `snapshots()`, `snapshot(_:)`,
  `snapshot(takenOn:)`), `SnapshotRates` (the `ratesJSON` column), `SnapshotStartBalances` /
  `SnapshotAccountBalance` (the `startBalancesJSON` column), `SnapshotJSON`, `ForecastSnapshotContent`,
  `ForecastSnapshotSummary` (picker row with end balances and `endNetWorth(in:)`).
- `AbacusDomain/Calc/ForecastSnapshotRetention.swift`: pure retention rule.
- `AbacusStore/Repositories/ForecastSnapshotRepository.swift` (`SQLiteForecastSnapshotRepository`):
  reads `scheduledItems` / `scheduledOccurrences` directly (no dependency on the N5a repositories),
  end-of-today balances via `SQLiteReportQueries.balances(on:)`, runs `ForecastEngine.run` with the
  `forecastHorizonDays` (default 90) and `scheduledGraceDays` (default 14) settings and stores its
  occurrences. Re-checks "no snapshot today" inside the write transaction. Prunes after taking.
- Tests: `AbacusStoreTests/ForecastSnapshotTests` (R-REC-17, 18), `AbacusDomainTests/ForecastSnapshotRetentionTests`.

### Step 5 — overlay and accuracy maths (R-REC-19, R-REC-20, R-REC-13 net worth)

- `AbacusDomain/Calc/ForecastOverlay.swift` (pure): `ForecastSeriesSelection` (`.netWorth(currency)` /
  `.account(id)`), `ActualDailyBalances` (days, currencies, balances, optional debt terms per day),
  `ForecastOverlay.make(snapshot:actual:occurrences:selection:today:)` → snapshot forecast over its whole
  horizon, actual line, gap day, actual/forecast at the gap, `gapMinor`, `ForecastGapSplit`
  (`scheduledMinor + otherMinor == gap`), `unconverted` currencies.
- `AbacusDomain/Calc/ForecastOverlayAccuracy.swift` (pure): `ForecastAccuracy.report(items:occurrences:period:)`
  → per item `ItemAccuracy` (rows with Δ day, Δ amount, Δ %, on time), `AccuracySummary` (paid / skipped /
  missed, on-time share, average |Δ %|), overall line, `suggestedAmountMinor` ("Update amount to X").
- Tests: `AbacusDomainTests/ForecastOverlayTests` (R-REC-19, 20, 13 debts) and an end-to-end store test
  in `ForecastSnapshotTests` (actual from `SQLiteReportQueries.balances(on:)` equals the balance calculator).

## Interpretations (decided in the lane, owner may revisit)

- **Rates JSON**: `{"asOf": "YYYY-MM-DD", "base": "UAH", "rates": {"EUR": "45.12"}}` — value of one unit
  in the base, decimals as strings (exact). Any pair converts through the base (cross rate). The caller
  builds it with `SnapshotRates.latest(from: converter, currencies:)` (today's latest rates, R-REC-13).
- **Start balances JSON**: `{"accounts": [{accountID, currency, isLiability, balanceMinor}], "debts": {"EUR": minor}}`.
  Only non-archived accounts (as the forecast). `debts` = signed debt terms that count in net worth
  (R-REC-13), passed in by the caller (the store does not evaluate `DebtBook`); held flat for the horizon.
- **Start balance** = balance at the **end** of the snapshot day (R-ACC-3, same as the Forecast tab).
- **Items**: one row per expected occurrence; `day` is the **expected** day (an overdue one keeps its
  past day; the overlay counts it on the snapshot day, like the forecast, Q12). First effect on
  `accountID`, a transfer's second effect on `toAccountID`.
- **Horizon** comes from `forecastHorizonDays` (default 90) although the spec says "always 90": the setting
  is the stored horizon (spec Q1), the screen selector is separate.
- **Retention**: daily for ages 0…119 days, then the earliest snapshot of each ISO week (Mon–Sun) for ages
  120…730, older deleted. Snapshots dated in the future (clock moved back) are kept.
  Pruning also deletes sync duplicates of one day (loser = older `createdAt`, then smaller id), and deletes
  items explicitly before headers.
- Read-side dedupe: newest `createdAt`, ties by the larger id string (stable on every device).

- **Overlay currency**: both lines at the snapshot's stored rates (R-REC-19). An account series stays in
  the account's currency. In a net-worth overlay a currency without a stored rate is left out on **both**
  sides (so it does not show as gap) and named in `unconverted`.
- **Actual line**: days of the input within [snapshot day, today]; when the data starts later the line
  starts there (clamped). **Gap day** = the last actual day that is also inside the snapshot horizon
  (today, or the horizon end for an old snapshot). No actual day → no gap, no split.
- **Gap split (Q13)**: scheduled = Σ over the snapshot's occurrences of (actual effect − forecast effect)
  up to the gap day. Forecast effect counts when max(expected day, snapshot day) ≤ gap day. Actual effect
  counts when the occurrence is `paid` with snapshot day < actual day ≤ gap day (the start balance is the
  end of the snapshot day, so a payment on that day is already in it); amount = `actualAmountMinor`, a
  transfer's received side scaled by paid/expected. Skipped, missed and still-open occurrences count 0.
  Everything else = gap − scheduled (unscheduled spending/income, edits, new accounts).
- **Net worth debts (R-REC-13)**: forecast adds the snapshot's `debts` flat; actual adds the caller's
  per-day debt terms (`ActualDailyBalances.debts`). The caller decides which accounts are in the actual
  input (non-archived; debt-linked accounts left out as in `Calc.netWorth`).
- **Accuracy**: Δ day = actual − expected day; on time = |Δ day| ≤ 1; Δ % relative to the occurrence's
  `expectedAmountMinor`; averages over paid rows with a known day/amount. `period` filters rows by
  expected day (snapshot day…today) or nil = all time. Occurrences of deleted items are kept (item nil).
- **"Update amount to X"**: the last three paid amounts (by expected day, any period) each differ from the
  template `amountMinor` by **more than** 2 % (exactly 2 % does not count); X = the **latest** paid amount
  (reflects the current price). Not offered when X equals the template.

## Left to do

- Callers (N5d / app shell): run `takeIfNeeded` at launch and on activation, **after** the matching sweep
  (R-REC-17), with `SnapshotRates.latest(from:currencies:)` and the debt terms.

## Shared-file requests

None so far.
