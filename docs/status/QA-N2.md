# QA-N2 — second quality check of Upcoming (N5b) and its wiring

Branch `wp/QA-N2-upcoming-check`, from `main` at `ad3b62c` (after the N5b and QA-N merges). Report only;
no code changed.

_Checked: 2026-11-17, debug build from this worktree (`build.noindex/qa-build`), scratch databases only
under `build.noindex/qa/` with `CFFIXED_USER_HOME=build.noindex/qa/home`; synthetic data only
(`-AbacusLoadSampleData YES`, the DEBUG `ForecastDemoSeed`, one hand-made two-row PKO file, one MCP
transaction)._

## Summary

| # | Check | Result |
|---|-------|--------|
| 1 | Bills, All items, editor, Forecast tab, dashboard widget, sidebar badge, light + dark | All present and close to the prototypes. **Converted amounts and totals go missing or stale** (H1) |
| 2 | Two launches on one scratch DB | Sweep and snapshot run at launch; second launch leaves every count unchanged |
| 3 | Import preview badge + headless commit | Badge "Matches scheduled: Water utility · 12.11.2026" shown; after `abacus-import` the occurrence is `paid` (`auto`). No count in the summary (L1) |
| 4 | `abacus-mcp --enable-writes` while the app runs | Propose → confirm → the app's foreign-write sweep pays the occurrence; Bills and badge follow |
| 5 | `swift test` with `ABACUS_SAMPLES` | 1350 tests green |

### QA-N findings, re-checked

- **QA-N H1 (N5b not merged, no sweep/snapshot at launch): resolved.** Upcoming is in the sidebar,
  `-AbacusSection upcoming` works, launch runs sweep → snapshot (check 2), the Forecast tab is hosted.
- **QA-N M1 (import preview badge never shown): mostly resolved.** The row badge shows in the review
  step (`import-preview.png`). Still open: `ImportPreview.scheduledMatchCount` is read nowhere (no figure
  in the review summary cards) and `abacus-import` prints no scheduled-match count — now L1.
- **QA-N M2 (MCP writes never matched): resolved** through the watcher: `databaseChangedElsewhere` runs
  the maintenance sweep; the MCP `Flat rent` expense paid the 5 Nov occurrence within seconds.
- QA-N L1 (snapshot harness does not quit while a sheet is open) still applies; editor snapshots here
  were ended by the run script.

## Findings

### High

**H1 — Upcoming shows amounts without conversion (or at an old rate) when its rates arrive after the
first load; totals are then wrong.**
Where: `AbacusFeatures/Upcoming/UpcomingModel.swift` — `converter` is `@ObservationIgnored`; `load()` sets it
after the observed data, and `refreshRates()` "touches" `displayCurrency` by assigning the same value.
Seen (all synthetic, reproducible):
- Second and later launches with `-AbacusSection upcoming` on a database that already has rates (cached
  and today's): header "NBU rates · 17 Nov 2026", but the range card says "No rate for EUR, PLN, USD; left
  out", totals **−398,00 ₴ / +0,00 ₴** instead of about −82 000 ₴ / +226 000 ₴, and no "≈ … ₴" line under
  any foreign amount (`rates-missing-second-launch.png`, `upcoming-dark.png`, `after-import-mcp.png`). Still
  the same after 12 s. On the same database at the same time the dashboard widget converts correctly
  (`dashboard-light.png`).
- First launch with sample data, All items: converted amounts use the **30 Jan** rates (Flat rent
  ≈ −39 007,36 ₴, i.e. 12.19 UAH/PLN) while Bills on the same data shows 30 Oct rates (≈ −36 904,96 ₴)
  (`all-items-light.png` vs `upcoming-light.png`); the monthly average is off accordingly.
Likely cause: with the Swift 6.2+ `@Observable` macro an assignment of an equal value does not notify,
so neither `phase = .loaded` (already loaded) nor `displayCurrency = currency` triggers a redraw, and the
new `converter` is never read by the view. Whenever no observed value changes after the converter does,
the screen keeps the old (empty or partial) table. Affects: Upcoming opened before the rate cache loads,
and any rate refresh (daily fetch, manual rate) while Upcoming is shown.
Suggested fix: make the converter (or a `ratesVersion` counter / the rate table's day) an observed
property, set it last in `load()` and in `refreshRates()`; add a model test that a `refreshRates()` with a
new table changes the totals the view reads (the view-level redraw is what fails).

### Medium

None found.

### Low

**L1 — The scheduled-match count is not shown (rest of QA-N M1).**
Where: `ImportPreview.scheduledMatchCount` has no reader in `App/` or `AbacusFeatures/`; the review summary
cards (All rows · New · Already imported · …) have no "Matches scheduled" figure, and the
`abacus-import` summary line has none either (dry run or commit). Suggested fix: a "N match scheduled
items" note under the cards (or a card), and "scheduled matches N" in the `abacus-import` summary.

**L2 — Badge date in the import row uses the numeric format.**
Where: `App/macOS/Import/ImportRowsTab.swift` / `ImportRowItem.scheduledBadge`: "Matches scheduled: Water
utility · 12.11.2026"; the prototype and the rest of Upcoming use "Thu, 12 Nov" / "12 Nov". Suggested fix:
format the expected day like the Upcoming rows (short day + month).

**L3 — Loading sample data creates 85 `missed` occurrences.**
Where: `UpcomingSample.items` (`createdAt` 1 Jan 2026, starts in January) with sample transactions that
never match them; the first sweep stores every past occurrence after the 14-day grace as missed
(85 of 85). The Forecast accuracy panel on sample data (without `-AbacusForecastDemo`) is then all
"0 of 10, 10 missed". Synthetic data only, but it is what the owner sees after "Load Sample Data".
Suggested fix: set the sample items' `createdAt` near the sample's "today" (or start them in the
sample's last month), or add matching sample transactions.

**L4 — A foreign write during a running maintenance task is not swept until the next trigger.**
Where: `AppSession.runScheduledMaintenance()` returns the running task when one exists, so a
`databaseChangedElsewhere` that arrives mid-sweep re-uses the sweep that started before the write
(code reading; not reproduced — the import and MCP writes here landed while idle). The next activation
or write catches it. Suggested fix: remember a "run again" flag and loop once more after the current
run.

**L5 — Editor sheet: large empty band above the footer; numeric "Starts" date.**
Where: `App/macOS/Upcoming/ScheduledItemEditorSheet.swift` (`editor-light.png`, `editor-dark.png`). The
sheet keeps a fixed height, leaving ~150 pt empty between Note and Delete…/Save; "Starts" shows
"5/ 1/2026" (stepper date field) while the next-date chips use "Sat, 5 Dec". Cosmetic. Suggested fix:
size the sheet to its content; consider the field-and-calendar date picker style used elsewhere, if any.

## Prototype comparison (`N5-upcoming.dc.html`, `N5-forecast.dc.html`)

Matches: Bills · Forecast tabs, Upcoming / All items (n), range card (Money out / Money in / Net,
7/30/90, rates note "Transfers are not counted"), groups Overdue · Today · This week · Later with counts,
row grid (tile, description + Overdue chip, category · repeat, account / "A → B", day + relative day,
amount with converted line, Mark paid, ⋯), All items table with search and "Average per month", editor
fields and footer (Expense/Income/Transfer, Repeat "Every N unit", Last day of the month, Ends, Next dates,
Match tolerance hint, Mode, Note, Delete… / Pause left, Cancel / Save right), dashboard "Upcoming (30
days)" card (status chip, totals, six rows overdue first, "N more · rates as of … · transfers not
counted", Open Upcoming), Forecast tab as in QA-N. Dark mode reads well everywhere.

Differences:
- Header: the Bills · Forecast segmented control sits left of the title; the prototype has the title left
  and the tabs at the right next to the rates label. Currency switch order EUR USD PLN UAH is app-wide.
- Sidebar badge is the grey system badge, not the red pill (documented in `N5b.md`).
- Editor has an extra "Event" row (R-REC-1 field) and no separator line in the prototype's place; date
  field numeric (L5).
- Import badge date format (L2).
- Suggestions card not seen: sample data has no qualifying pattern (as in N5b).
- Forecast: the differences listed in QA-N (step lines, end-of-day values, ±mean day shift, today's
  values line instead of the hover hint) remain; the Bills | Forecast switch is now there.

## Check details

- **Two launches (check 2)**, `two.sqlite`, sample data on the first launch:
  after launch 1 `scheduledItems 9, scheduledOccurrences 85 (all missed, L3), forecastSnapshots 1
  (takenDay 2026-11-17), forecastSnapshotItems 30, txns 26`; after launch 2 and a third launch: identical,
  same snapshot id.
- **Import (check 3)**, `imp.sqlite` (copy after the two launches): `pko-qa.csv` (two synthetic rows:
  −140.00 PLN "WATER UTILITY" on 13 Nov, −23.40 PLN coffee) — preview badge on the first row only. With the
  app running, `abacus-import --db imp.sqlite --pko-account "PKO Personal"`: created 2; occurrence
  `Water utility 2026-11-12 → paid, actualDay 2026-11-13, matchKind auto`.
- **MCP (check 4)**, same file, app running: `create_transaction` (expense 3200.00 PLN "Flat rent",
  2026-11-06, PKO Personal) → `status proposed` + token, nothing written; second call → `done`, txns +1.
  Within the next seconds `Flat rent 2026-11-05 → paid, actualDay 2026-11-06, auto`. Relaunch: both rows
  gone from Overdue, badge 7 → 5 (`after-import-mcp.png`).
- **Forecast demo**: `-AbacusForecastDemo YES` on a fresh file gives 7 items, 35 occurrences (27 paid,
  8 missed), 5 snapshots; chart, below-zero warning and accuracy panel render in light and dark. The
  large drop on 11 Dec is the demo's "Car insurance" item (73 471,40 zł a year), not a bug.

## Not checked, and why

- Clicking Mark paid, Skip, ⋯ menu, Link existing…, suggestion Accept/Dismiss in the running app — no
  Accessibility permission for synthetic clicks; model paths are unit-tested (`UpcomingTests`).
- Rate refresh while Upcoming is already on screen (H1's second case) is inferred from the code and the
  launch behaviour, not watched live.
- Activation trigger (`didBecomeActive`) on a new day; overlay with a past snapshot in the Forecast tab
  (needs menu input).

## Screens (`docs/status/QA-N2-screens/`, downscaled)

`upcoming-light.png` (first launch, converted), `upcoming-dark.png` (second launch, H1),
`rates-missing-second-launch.png` (H1), `all-items-light.png` (H1, January rates), `editor-light.png`,
`editor-dark.png`, `forecast-light.png`, `forecast-dark.png`, `dashboard-light.png` (widget converts),
`dashboard-dark.png` (demo data), `import-preview.png` (badge), `after-import-mcp.png`.

## Gate

`swift test` with `ABACUS_SAMPLES` from `AbacusKit/`: 1350 tests green (Domain 188, FX 40, Import 293,
Features 656, MCP 46, Store 127). App build from `main` (`ad3b62c`): BUILD SUCCEEDED.
