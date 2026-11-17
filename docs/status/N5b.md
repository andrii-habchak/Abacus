# N5b — Upcoming UI and app wiring (lane `wp/N5b-upcoming-ui`)

Scope: step 6 of `docs/status/N5.md` (R-REC-4, 10–12, 16; wiring of R-REC-7a/b/c and R-REC-17).
Prototypes: `docs/design/N5-upcoming.dc.html`, dashboard widget in `docs/design/N5-forecast.dc.html`.
Branch cut from `main` at the N5a merge (`96849aa`).

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
  Pause at the left), `UpcomingForecastPlaceholder` (`Text("Forecast")`, to be swapped for N5d's
  `ForecastView` at merge). `App/macOS/Dashboard/DashboardUpcomingCard.swift`.
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
- **Snapshot debt terms**: debts with "Count in net worth" (`Calc.debtBalances`) minus the balances of
  all non-archived debt-linked accounts, because `Calc.netWorth` leaves linked accounts out while the
  snapshot stores every non-archived account. Rates: `SnapshotRates.latest` over account and debt
  currencies, base UAH.
- Maintenance runs once at a time; after the run the Upcoming data reloads (badge, widget).

## Requests to the orchestrator

- PreviewData / sample data: "Load Sample Data" now seeds `UpcomingSample` items from
  `AppSession.loadSampleData` (no `PreviewData` edit). If the orchestrator prefers it inside
  `SampleData.seed`, move the call.
- At merge: replace `UpcomingForecastPlaceholder()` in `UpcomingView.content` with N5d's view.

## Left / not done

- Visual check and screenshots (`docs/status/N5b-screens/`) — in progress.
