# N3b — owner fixes (D73)
Branch `wp/N3b-owner-fixes` from `origin/main`.

1. **Debt filter restores the date range.** Already in place since C28 (`dateRangeBeforeDebt`, set by
   `TransactionsViewModel.filters(showingDebt:)`, restored by `TransactionFilters.removeDebt` when the
   last debt goes; a range picked by hand clears it). The C24 / N3 notes saying it stays "All dates"
   were stale. No code change; added test `DebtFilterDateRangeTests` (R-DEBT-22 / C24, D73) that pins
   both the restore and the hand-picked case.
2. **Per-currency caption under the debt total.** `DashboardDebts.totalCaption`: the open balances summed
   per currency, display sign, joined by " · " (e.g. "−zł1,200 · +€300"), only when more than one
   currency is open (`DebtSign.caption`), shown under the widget total in `DashboardDebtsCard`. Debt
   rows already carried the same rule (C25). Test `DebtsUITests.totalCaption` (D73, R-DEBT-21).

Gate: `swift test` 1,123 green; app build succeeded. Not checked visually (caption layout on the card).
