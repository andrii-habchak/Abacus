# N5b — Upcoming UI and app wiring (lane `wp/N5b-upcoming-ui`)

Scope: step 6 of `docs/status/N5.md` (R-REC-4, 10–12, 16; wiring of R-REC-7a/b/c and R-REC-17).
Prototypes: `docs/design/N5-upcoming.dc.html`, dashboard widget in `docs/design/N5-forecast.dc.html`.
Branch cut from `main` at the N5a merge (`96849aa`); `main` with N5d (`0502b06`) merged in.

_Last update: 2026-11-17._

## Done

- **View models** `AbacusFeatures/Upcoming/`:
  - `UpcomingCalc` (pure): occurrences of a range (expected from `ScheduledOccurrences.expected` plus
    paid/skipped rows dated today or later), groups Overdue · Today · This week (1–7 days) · Later,
    badge count (overdue + next 7 days, unresolved), header totals (display currency, latest rate,
    transfers out, missing rates named), repeat labels, monthly average, relative days.
  - `UpcomingModel`: Bills / Forecast tabs, Upcoming / All items views, range 7/30/90, row actions
    (Mark paid → `onMarkPaid` with a `TransactionTemplate`; `paid` after the editor saved; Skip;
    Link existing… picker (same account and type, ±`dayWindow` days, probe-able, not linked
    elsewhere, nearest day then amount); Unlink / Undo skip = `reopen`), All items rows (chips
    Paused / Account archived / Ended / Account missing, next date, monthly average), suggestions
    (`SubscriptionDetector` off the main actor, evidence rows, Accept → editor pre-filled, Not now,
    Dismiss, Show dismissed → Restore), notices, editor routing.
  - `ScheduledItemEditorModel` + `ScheduledItemDraft`: fields per R-REC-1, validation issues,
    next five dates (`Schedule.next(5, onOrAfter: today)`), month-end hint, save / pause-resume /
    delete through the N5a store.
  - `UpcomingDependencies` (`live`, `preview`, `onDatabase`), `UpcomingSample` (synthetic items on
    the `PreviewData` accounts), `UpcomingMaintenance` (sweep → snapshot, debt terms).
  - `Dashboard/DashboardUpcoming.swift`: widget data (≤ 6 rows, overdue first, totals, "N more ·
    rates as of … · transfers not counted", status chip, empty state).
- **Views** `App/macOS/Upcoming/`: `UpcomingView` (toolbar segmented Bills · Forecast, "New scheduled
  item", rates label + display currency from the shell toolbar; Upcoming/All items segmented,
  suggestions card, range card with totals, grouped rows with Mark paid + ⋯ menu and context menu,
  link sheet, All items table), `ScheduledItemEditorSheet` (D55 sheet, Save bottom-right, Delete… /
  Pause at the left); the Forecast tab hosts N5d's `ForecastView(model: session.forecast, …)`.
  `App/macOS/Dashboard/DashboardUpcomingCard.swift`.
- **Forecast wiring** (orchestrator's addition after the N5d merge): `AppSession.forecast`
  (`ForecastModel(dependencies: .live(database:refresher:format:))`, preview on `UpcomingSample`); it
  reloads after `dataChanged()`, after the maintenance run (launch, activation, foreign write) and after
  rates change when shown; `forecast.onDataChange` reloads Upcoming ("Update amount to X");
  `upcoming.onDataChange` reloads a shown forecast. DEBUG `-AbacusForecastDemo YES` with
  `-AbacusLoadSampleData YES` seeds `ForecastDemoSeed` instead of `UpcomingSample` (scratch DB only).
- **Wiring** (granted edits, see the list below): section `upcoming` (sidebar after Events, badge,
  `-AbacusSection upcoming` works through the existing parser), `AppSession.upcoming`; at start (after
  the rate cache), on `didBecomeActive` and after a foreign write: `UpcomingMaintenance.run` (sweep with
  `ScheduledMatch.rule`, then `SQLiteForecastSnapshotRepository.takeIfNeeded` with
  `SnapshotRates.latest` and the debt terms) off the main actor, then the Upcoming data reloads; after
  the editor saves: a "Mark paid" records `markPaid(kind: .typed)`, any other save runs
  `matchTransaction`; "Load Sample Data" also seeds `UpcomingSample` items; the import review row shows
  "Matches scheduled: <item> · <day>" from `PreviewRow.scheduledMatch`.
- **Tests** `AbacusKit/Tests/AbacusFeaturesTests/Upcoming/UpcomingTests.swift` (16): grouping, sample
  groups + badge, totals and missing rates, repeat labels, skip/undo, mark paid, link existing +
  unlink, editor validation + next dates + month end, editor save/edit/pause/delete, All items,
  suggestions flow (accept/not now/dismiss/restore), accepted suggestion disappears, dashboard
  widget + empty state, launch run (sweep + one snapshot a day), section registration.
  Updated expectations in `AppModelTests` (sidebar order, currency switch, New transaction) and
  `DashboardWidgetsTests` (default order now ends with `.upcoming`).

## Edits outside the owned paths (granted this wave; please review at merge)

- `AbacusFeatures/App/AppBootstrap.swift`: `AppSection.upcoming` (title, `clock` icon, display
  currency yes, New transaction no, in `overview` after Events).
- `AbacusFeatures/Dashboard/DashboardLayout.swift`: `DashboardWidget.upcoming` (half width, appended to
  the default order).
- `AbacusFeatures/Shell/AppSession.swift`: `upcoming` model, `pendingPayment`, maintenance task,
  activation observer, `editorFinished` matching, `sectionAppeared`, rates refresh, sample items.
- `AbacusFeatures/Editor/EditorDraft.swift` + `TransactionEditorModel.swift`:
  `TransactionEditorMode.newFromTemplate(TransactionTemplate)` and its prefill (type, account(s),
  amount, received amount, category, event, description, note; the date stays now).
- `AbacusFeatures/Import/ImportContent.swift` (`ImportRowItem.scheduledBadge`) and
  `App/macOS/Import/ImportRowsTab.swift` (badge under the description).
- `App/macOS/Shell/RootView.swift` (section routing, widget, sidebar badge), `SidebarView.swift`
  (`.badge`), `App/macOS/Dashboard/DashboardView.swift` (`upcoming:` widget view).
- Tests: `AppModelTests.swift`, `DashboardWidgetsTests.swift` expectations.

## Interpretations (decided here, owner may revisit)

- **Tabs**: the prototype wins over the brief's "Bills · All items · Forecast": the toolbar has
  Bills · Forecast, and Bills has Upcoming · All items (as `N5-upcoming.dc.html`).
- **Mark paid** opens the New transaction editor with today's date and time (paying now); the
  occurrence is recorded `typed` for that transaction. Cancel records nothing.
- **Resolved rows** show only when dated today or later (as the prototype); a paid overdue row
  disappears from Bills. Missed rows never show here (accuracy panel, N5d).
- **Not now** lasts for the session (no setting key exists; adding one is a Model change).
- **Link existing…** lists transactions of the item's type on its account within ±3 days, whatever
  the amount or description (the owner picks), excluding ones linked to another occurrence.
- **Sidebar badge** uses the system `.badge` (grey count in the macOS sidebar), not the prototype's
  red pill: List badges cannot be tinted.
- With 11 sidebar sections, Import (the 11th) has no ⌘-digit any more (`AppModel.shortcutKeys`
  stops at ⌘0). Orchestrator: decide whether to keep it so.
- **Snapshot debt terms** (kept instead of `ForecastDebtTerms.terms`, which leaves linked accounts in
  the debt term while the snapshot store also keeps those accounts in its start balances — that would
  count them twice): debts with "Count in net worth" (`Calc.debtBalances`) minus the balances of
  all non-archived debt-linked accounts, because `Calc.netWorth` leaves linked accounts out while the
  snapshot stores every non-archived account. Rates: `SnapshotRates.latest` over account and debt
  currencies, base UAH.
- Maintenance runs once at a time; after the run the Upcoming data reloads (badge, widget).

## Requests to the orchestrator

- PreviewData / sample data: "Load Sample Data" now seeds `UpcomingSample` items from
  `AppSession.loadSampleData` (no `PreviewData` edit). If the orchestrator prefers it inside
  `SampleData.seed`, move the call.
- N5d's accounts exclude debt-linked accounts but `SQLiteForecastSnapshotRepository` stores every
  non-archived account; my debt terms subtract the linked balances so the snapshot's end net worth
  matches. Worth one look by the orchestrator when comparing overlay and snapshot.
- `abacus-import` still posts no Darwin notification (N2r note); its writes are swept on the next poll /
  activation.

## Visual check (17 Nov 2026, debug app on scratch databases)

`-AbacusDatabasePath <scratch>/demo.sqlite -AbacusLoadSampleData YES`, `CFFIXED_USER_HOME=<scratch>`,
`-AbacusSection upcoming|dashboard`, `-AbacusUpcomingView all`, `-AbacusUpcomingEditor first`,
`-AbacusUpcomingTab forecast`, in-app snapshots, PLN display currency. Screens in
`docs/status/N5b-screens/`: Bills light/dark, All items, editor sheet light/dark, dashboard widget
light/dark, Forecast tab light/dark (`ForecastDemoSeed` data). Compared with `N5-upcoming.dc.html`:
same structure (toolbar tabs, Upcoming/All items, range card with totals and note, groups with counts,
row grid, chips, Mark paid + ⋯), editor fields and footer as the sheet; widget as `N5-forecast`
dashboard. Differences: native segmented controls and system sidebar badge (grey), no prototype strip.
Found and fixed during the check: next-date chips wrapped (now one line, sheet 660 pt); rates arriving
before the first Upcoming load were dropped (now always taken). The suggestions card does not show on
the sample data (no pattern in it); covered by tests.

## Left / not done

- Suggestions card not seen in the running app (sample data has no qualifying pattern).
- No UI test of the ⋯ menu / link sheet in the running app (model paths are unit-tested).
