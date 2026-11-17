# N5b-fix — QA-N2 findings in Upcoming (H1, L1–L5)

Branch `wp/N5b-fix-qa`, from `main` at `fec5510` (after the QA-N2 merge). Scope: the new findings of
`docs/status/QA-N2.md`. Out of scope (documented choices): grey sidebar badge, tab-control position,
the editor's Event row.

## Done

| # | Finding | Fix | Test |
|---|---------|-----|------|
| H1 | Converted totals / "≈" lines missing or at old rates after rates arrive; All items and Bills on different rate days | `UpcomingModel.converter` is now observed, and a `ratesVersion` counter is bumped last in `load()` and `refreshRates()` (`setRates`). One converter serves Bills, All items and the editor; the "touch `displayCurrency`" trick is gone (an equal assignment no longer notifies) | `UpcomingRatesTests.ratesAfterLoad`: load without rates, deliver rates, `refreshRates()`; the view-level observation of `totals`, `groups` and `monthlyAverageText` fires and the totals convert (R-REC-10). `reloadNotifies`: a reload notifies even when nothing else changed |
| L4 | A foreign write during a running sweep waited for the next trigger | `AppSession.runScheduledMaintenance()`: a call while a run is in progress sets a rerun flag; the task loops once more (coalesced, at most one pending) and the returned task ends after that run | `maintenanceRerun`: two triggers after the sweep read the data give exactly one extra run; idle again → one fresh run |
| L1 | `scheduledMatchCount` read nowhere | Review step: a note under the summary cards, "2 rows match scheduled items · marked paid on import" (`ImportWizardModel.scheduledMatchNote`, hidden at 0). `abacus-import` prints `  scheduled matches: N` after each file's counts line (dry run and commit; counts only; `run()` error structure kept) | visual check; tool run below |
| L2 | Badge date "12.11.2026" | `ImportFormat.shortDay` → "Matches scheduled: Water utility · 12 Nov" | `importBadgeDay` |
| L5 | Editor: empty band above the footer; "Starts" numeric | Sheet sizes to its content (`presentationSizing(.fitted)`, scroll area capped at 640 pt, scrolls only when needed). Starts / End day are a text button in the app's style ("Sat, 5 Sep 2026", `ScheduledItemEditorModel.fieldDayText`) with a calendar popover (graphical picker) | visual check |
| L3 | Load Sample Data stored 85 missed occurrences | `UpcomingSample.seedIfAbsent(_:today:calendar:)` starts the items two months before today (same day of month; month-end items on the month's last day; `createdAt` = start), and adds one synthetic paid transaction per past occurrence of Flat rent, Salary, Streaming service and Phone plan. The in-memory `UpcomingSample.database()` for previews/tests is unchanged | `sampleNearToday`: starts in the month two before today; paid ≥ 6, 0 < missed < 15 |

### Interpretations

- L1 wording: the brief's "N match scheduled items" written as a sentence with the row count and what
  happens ("· marked paid on import"); the wizard's secondary caption style, no new card (cards filter
  rows; a scheduled match is not a row status).
- L5 "app's date style": the next-date chips' style plus the year, since a start day can be in another
  year. Other screens use the numeric `.field` picker; the brief asked for the Upcoming style here.
- L3: both suggested remedies (start near today and matching sample transactions). The sample
  transactions use ids 960–992 and are only added by Load Sample Data, not by `PreviewData`.
- One code commit for all six fixes: they share `AppSession.swift` and the new test file, and the gate
  ran on the final tree.

## Verified

- `swift test` with `ABACUS_SAMPLES` from `AbacusKit/`: 1355 tests green (Domain 188, FX 40, Import 293,
  Features 661, MCP 46, Store 127). App build (`build.noindex/fresh`): BUILD SUCCEEDED.
- Visual check (debug build `build.noindex/fresh`, scratch databases under `build.noindex/qa/` with
  `CFFIXED_USER_HOME=build.noindex/qa/home`, synthetic data only; screens in `docs/status/N5b-fix-screens/`):
  - H1: two launches on one file with `-AbacusLoadSampleData YES -AbacusSection upcoming`. The second
    launch (the case QA-N2 saw fail) shows totals −44 279,24 ₴ / +111 220,20 ₴ with today's rates
    and a "≈ … ₴" line under every foreign amount (`upcoming-second.png`). All items converts at the
    same rates as Bills (Flat rent ≈ −36 316,80 ₴ on both; `all-items.png`).
  - L3: after Load Sample Data the database holds 7 paid and 13 missed occurrences (was 85 missed);
    badge 4.
  - L1/L2: QA-N2's synthetic two-row PKO file in the review step: "1 row matches a scheduled item ·
    marked paid on import" under the cards, badge "Matches scheduled: Water utility · 12 Nov"
    (`import-preview.png`). `abacus-import --dry-run` prints `  scheduled matches: 1`.
  - L5: editor sheet (`-AbacusUpcomingEditor first`), light and dark: no empty band, Starts
    "Sat, 5 Sep 2026" with a calendar icon (`editor-light-sheet.png`, `editor-dark-sheet.png`).

## Not done / left

- The calendar popover of the day fields and a rate refresh while Upcoming is on screen were not
  clicked or watched live (no Accessibility permission for synthetic clicks); the model path of the
  refresh is covered by `ratesAfterLoad`.
- Full gate was run on the final tree only (the fixes share files, one code commit).
