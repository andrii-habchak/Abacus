# N5d — Forecast UI (lane `wp/N5d-forecast-ui`)

Scope: the Forecast tab of Upcoming (R-REC-13…15, R-REC-19, R-REC-20) against the approved prototype
`docs/design/N5-forecast.dc.html` (Forecast part only), plus the `abacus-import` change notification.

_Last update: 2026-11-17._

## Done

- **abacus-import notifies the app** (N2r follow-up): after a successful non-dry-run write (remembered
  PKO account, balance correction or an import commit) the tool posts the Darwin notification
  `io.github.andrii-habchak.Abacus.database-changed` once at the end, the same call as `abacus-mcp`
  (`DarwinNotifier`). The name is spelled out in `AbacusImportTool/main.swift` because the tool does not
  depend on `AbacusMCP` (no `Package.swift` change).

## In progress

- View model `AbacusFeatures/Forecast/`, view `App/macOS/Forecast/ForecastView.swift`.
