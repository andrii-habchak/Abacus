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

## Left to do

- Step 5 (overlay + accuracy maths) — see below once done.
- Callers (N5d / app shell): run `takeIfNeeded` at launch and on activation, **after** the matching sweep
  (R-REC-17), with `SnapshotRates.latest(from:currencies:)` and the debt terms.

## Shared-file requests

None so far.
