# N5d — Forecast UI (lane `wp/N5d-forecast-ui`)

Scope: the Forecast tab of Upcoming (R-REC-13…15, R-REC-19, R-REC-20) against the approved prototype
`docs/design/N5-forecast.dc.html` (Forecast part only; its dashboard widget is N5b's), plus the
`abacus-import` change notification.

_Last update: 2026-11-17._

## Done

- **abacus-import notifies the app** (N2r follow-up): after a successful non-dry-run write (remembered
  PKO account, balance correction or an import commit) the tool posts the Darwin notification
  `io.github.andrii-habchak.Abacus.database-changed` once at the end, the same call as `abacus-mcp`
  (`DarwinNotifier`). The name is spelled out in `AbacusImportTool/main.swift` because the tool does not
  depend on `AbacusMCP` (no `Package.swift` change).
- **View model** `AbacusKit/Sources/AbacusFeatures/Forecast/`:
  - `ForecastDependencies` (closures + repositories; `live(database:refresher:)`, `database(_:rates:today:format:)`).
  - `ForecastModel` (`@MainActor @Observable`): horizon 30/60/90 (default = setting `forecastHorizonDays`,
    else 90), series net worth / one account, display currency, projection from `ForecastEngine.run`
    (today's end-of-day balances + scheduled items only), lowest point, below-zero warnings with the
    causing items and the recovery day, net worth with debt terms, snapshot picker, overlay
    (`ForecastOverlay.make`) with gap and gap split, accuracy (`ForecastAccuracy.report`) scoped
    "Since <snapshot day>" / "All time", expandable rows, `applySuggestion` ("Update amount to X" saves
    the item through `ScheduledItemRepository.save`), `detail(for:)` hover text.
  - `ForecastDebtTerms`: debt terms per currency (linked accounts + manual records of debts with "Count
    in net worth"), per day for the actual line; also usable as the `debts:` argument of
    `ForecastSnapshotRepository.takeIfNeeded` when N5b wires snapshots.
  - `ForecastFormat` (two decimals, true minus, "18 Dec", "Tue 18 Dec").
  - `ForecastDemoSeed` (DEBUG only): synthetic scheduled items from the sample data's recurring
    transactions, a large yearly bill, past snapshots, then the matching sweep — for UI reviews on a
    scratch database only.
- **View** `App/macOS/Forecast/`: `ForecastView` (chart card with series menu, horizon segments, past
  forecast menu, summary Now / In N days / Change / Lowest point, chart, hover line, legend, rates note;
  warning box; "Forecast vs reality" gap card; accuracy card), `ForecastChart` (Swift Charts),
  `ForecastAccuracyCard`, `ForecastDebugHost` (DEBUG, not referenced by the shell).
- **Tests** `AbacusKit/Tests/AbacusFeaturesTests/Forecast/ForecastModelTests.swift` (R-REC-13, 14, 15, 19, 20).

## Visual check

Screens in `docs/status/N5d-screens/` (light and dark): today's forecast only, overlay with the accuracy
panel and an expanded row, and an account series with the below-zero warning. Rendered by a preview
snapshot harness kept outside the repo (a scratch Swift package hosting `ForecastView` in an off-screen
`NSHostingView` over a scratch database: `SampleData` + `ForecastDemoSeed`, `PreviewData.today`,
`PreviewData.fxRates`). The shell could not be edited to host the view (shared file), so the in-app
`-AbacusForecastDemo` host (`ForecastDebugHost`) is ready but not referenced; the orchestrator can
check it in the app once the Upcoming tab hosts `ForecastView`. Never run on the real database.

Seen and fixed: gap label struck through by the lines (now on a card-coloured tag), chart top padding
for the "Today" label. Known look differences from the prototype: Swift Charts step lines
(`.stepEnd`) instead of straight segments, so balances change on the day of the occurrence; menus and
segmented controls are the native ones.

## For the orchestrator (merge)

`ForecastView` is self-contained. Two initialisers (internal to the app target, like the other screens):

```swift
// With a model the session keeps (selections survive tab switches) — preferred:
ForecastView(model: ForecastModel, displayCurrency: Currency)
// Or with its own model:
ForecastView(dependencies: ForecastDependencies, displayCurrency: Currency)
```

Wiring in `AppSession` (shared file, not touched here): `let forecast = ForecastModel(dependencies:
.live(database: database, refresher: refresher, format: …), displayCurrency: app.displayCurrency)`; in
the Upcoming section's Forecast tab: `ForecastView(model: session.forecast, displayCurrency:
app.displayCurrency)`. The view calls `model.load()` on appear; call `await session.forecast.load()` from
`dataChanged()` / the database-change reload so it follows other writes. Set `forecast.onDataChange` to
reload the Upcoming lists after "Update amount to X". The page has no own toolbar; the display currency
switch is the shell's (prototype: Upcoming's bar).

Snapshots (N5b wires `takeIfNeeded` after the sweep): debts argument =
`ForecastDebtTerms.terms(book:accountBalances:currencies:day:)` with today's balances.

## Interpretations (decided in the lane)

- **Accounts in the forecast**: non-archived accounts **not linked to a debt**; a linked account's value is
  in net worth through its debt (R-DEBT-18), as in `Calc.netWorth`. Items on a linked account are left out.
- **Debt terms** are today's balances held flat for the whole horizon (R-REC-13); a record dated after
  today does not count.
- **Net worth rates**: `SnapshotRates.latest` from the current converter (today's latest rates, flat).
  Currencies without a rate are left out and named in the note.
- **Warning causes**: the occurrences effective on the first below-zero day (prototype: "after “Rent”");
  when none falls on that day, the latest outgoing one before it. The warning also shows the lowest
  balance of that below-zero stretch and the day it is back at or above 0.
- **Accuracy scope**: "Since <snapshot day>" / **"All time"** (TA R-REC-20 wording; the prototype's
  "Last 120 days" was a placeholder). Without a snapshot: All time. Avg. day shift = mean |Δ day| of paid
  rows; Avg. amount Δ = mean |Δ %| (TA: average absolute deviation), red above 2 %.
- **"Update amount to X"** is a button (the prototype's chip); it saves the item's `amountMinor` (a
  same-currency transfer's `toAmountMinor` is cleared so it follows). Resolved occurrences keep their
  expected amounts (R-REC-4).
- **Snapshot picker** default: none ("None — today’s forecast only"); disabled with "no past forecasts yet".
- Values are **end-of-day** balances (R-ACC-3, same as N5c's snapshot start), so the note says so
  (the prototype said "start of each day").

## Shared-file requests

- Orchestrator: host `ForecastView` in the Upcoming Forecast tab and keep a `ForecastModel` in
  `AppSession` (see above). No other shared file needed.
