# QA-N — quality check of the N2r / N5a / N5c / N5d / N7c wave

Branch `wp/QA-N-wave-check`, from `main` at `0502b06` (merge of N5d). Report only; no code changed.

_Checked: 2026-11-17, debug build from this worktree (`build.noindex/qa-build`), scratch databases only
under `build.noindex/qa/` with `CFFIXED_USER_HOME=build.noindex/qa/home`; synthetic data only
(`-AbacusLoadSampleData YES`, the DEBUG `ForecastDemoSeed`, test fixtures and one hand-made PKO row)._

## Summary

| # | Check | Result |
|---|-------|--------|
| 1 | Upcoming, Bills, All items, item editor, dashboard Upcoming (30 days) | **Not checkable: N5b is not on `main`** (H1) |
| 1 | Forecast tab (`-AbacusForecastDemo YES`) | Not reachable in the app as merged (H1); checked with a local, uncommitted host patch — matches the prototype apart from the differences below |
| 2 | Launch twice: sweep idempotent, one snapshot per day | App launch runs neither sweep nor snapshot (H1). Second launch: counts unchanged (trivially). Store-level idempotency covered by unit tests |
| 3 | `abacus-import` while the app runs | Reload works (watcher log line). Commit-time scheduled match works. Preview badge not shown anywhere (M1) |
| 4 | `abacus-mcp --enable-writes` propose + confirm | Works; app reloads (watcher log line). MCP writes are never matched (M2) |
| 5 | Lock with an open sheet | Sheet and toolbar hidden while locked, back after unlock (snapshots). Two low findings |
| 6 | Full gate | see "Gate" below |

## Findings

### High

**H1 — Upcoming UI (N5b) is not merged; nothing in the app runs the N5 sweep or snapshot.**
Where: `main`; `AppSection` has no `upcoming` case (`-AbacusSection upcoming` is ignored);
`origin/wp/N5b-upcoming-ui` has no commits beyond `main`. Consequences, all on `main` today:
- No Upcoming section, Bills, All items, suggestions card, item editor, dashboard widget
  "Upcoming (30 days)" (`dashboard-no-upcoming-widget.png`: the dashboard has no such card).
- `SQLiteScheduledStore.sweep` (R-REC-7c, R-REC-9) and `ForecastSnapshotRepository.takeIfNeeded`
  (R-REC-17) are called only by the DEBUG `ForecastDemoSeed`, never at launch / activation.
  Two launches on one scratch file with sample data: `scheduledItems 0, scheduledOccurrences 0,
  forecastSnapshots 0` both times.
- `matchTransaction` after an editor save (R-REC-7b) is not called anywhere in the app.
- `ForecastView` is hosted only by `ForecastDebugHost`, which nothing references, so
  `-AbacusForecastDemo YES` has no effect in the merged debug build.
Suggested fix: land N5b with the orchestrator's shell hooks (sidebar item, dashboard slot, Forecast tab
hosting `ForecastView` with a session `ForecastModel`), and wire sweep → `takeIfNeeded` at launch and on
activation (N5a/N5c "For the orchestrator" notes), plus `matchTransaction` in `editorFinished`.

### Medium

**M1 — Import preview badge "Matches scheduled: <item> · <day>" (R-REC-7a) is never shown.**
Where: core computes `PreviewRow.scheduledMatch` and `ImportPreview.scheduledMatchCount`
(`AbacusImport/Dedupe/RowAnalyzer.swift`), but nothing under `App/` or `AbacusFeatures/` reads them, and
the N5b scope in `docs/PLAN.md` does not list the import review step. `abacus-import` does not print the
count either (its summary line has no "scheduled" figure, dry run or commit).
Verified that the commit-side match works: a synthetic PKO row (−129.00 PLN, 2026-11-17, "GYM
MEMBERSHIP") on the demo database paid the "Gym membership" occurrence expected 2026-11-20
(`status paid, actualDay 2026-11-17, matchKind auto`), while the app was running.
Suggested fix: add the badge per row and the count in the review step summary of the import wizard
(assign to N5b or a small follow-up), and a "scheduled matches N" figure in the `abacus-import` summary.

**M2 — Transactions written by `abacus-mcp` are never matched to scheduled items.**
Where: `AbacusMCP/Tools/WriteTools.swift` `create_transaction` / `update_transaction` do not call the
matcher; the TA relies on the launch sweep (R-REC-7c, "later, MCP writes"), which is not wired (H1).
Effect today: an MCP-created bill stays unmatched until the sweep exists. Resolves with H1's wiring; if
the sweep should also run when the watcher sees a foreign write (`databaseChangedElsewhere`), add it there.

### Low

**L1 — Snapshot harness: the app does not quit after the snapshot while a sheet is open.**
Where: `App/macOS/Shell/WindowSnapshot.swift` `NSApp.terminate(nil)`. With `-AbacusOpenSheet editEvent`
(with or without `-AbacusLockTest`) the snapshot is written but the process keeps running; scripted
runs hang until killed. Suggested fix (DEBUG only): close attached sheets (`endSheet`) before
`terminate`, or `exit(0)` after the capture.

**L2 — Lock screen over a hidden sheet looks inactive.**
Where: `App/macOS/Lock/LockWindowShield.swift`. While locked with a hidden sheet the window renders as
not key: grey traffic lights, dimmed text and buttons, so Unlock / Quit look disabled
(`lock-2-locked-light.png`, `lock-2-locked-dark.png`; compare N7c's plain lock screen). Clicks are
routed (N7c), so it is cosmetic. Suggested fix: keep the parent window's active appearance while the
shield is up, or make the lock content key-looking (e.g. `.environment(\.controlActiveState, .key)`
on `LockView`).

**L3 — `-AbacusLockTestPlan` log line reports the state before the shield applies it.**
Where: `App/macOS/Lock/LockView.swift` `runPlan`. After "lock" the log says the sheet has `alpha 1.0`
and the title is the section name; after "unlock" `alpha 0.0` and title "Abacus" — the snapshots show
the opposite (correct) state. Misleading for whoever reads the log. Suggested fix: log after a run-loop
turn (`await Task.yield()` / short sleep) before reading windows.

**L4 — `abacus-import` traps on usage errors.**
Where: `AbacusKit/Sources/AbacusImportTool/main.swift` (top-level `try`). A missing `--pko-account` or an
unknown account name ends with `Fatal error: Error raised at top level` and leaves a crash report in
`~/Library/Logs/DiagnosticReports/abacus-import-*.ips` (several there from earlier runs). Suggested fix:
wrap the body in `do { … } catch { FileHandle.standardError.write(…); exit(1) }` (more than a few lines
because the file is a top-level script, so not fixed here).

## Forecast tab vs prototype (`docs/design/N5-forecast.dc.html`)

Seen in `forecast-demo-light.png` / `forecast-demo-dark.png` (local host patch, demo seed on sample data).
Matches: series menu, 30/60/90 segments, "Compare with a past forecast" menu, Now / In N days / Change /
Lowest point, "Today" marker, dashed "Forecast made today" legend, rates note, amber below-zero warning
with lowest balance and recovery day, accuracy card with per-item rows, missed chips, "Update amount to
X" chip, red Δ above 2 %, footnote. Dark mode reads well.
Differences (none blocking; most are documented N5d interpretations):
- No Bills | Forecast switch in the header (it belongs to the Upcoming host, H1).
- Step lines instead of straight segments; end-of-day values ("Values are end-of-day balances") instead
  of the prototype's start-of-day — both documented in `N5d.md`.
- "Hover the chart for a day's values." hint is replaced by today's values line
  ("Tue, 17 Nov · forecast …").
- Avg. day shift shows "±0,8 d" (mean |Δ day|) where the prototype shows a signed "+1.0 d" — matches the
  N5d interpretation, owner may prefer signed.
- Accuracy scope shows only "All time" until a past forecast is picked (prototype shows two choices).
- Overlay with a past snapshot (gap card, overlay legend) not re-checked in the app: the menu needs
  input and there is no launch option for it; `docs/status/N5d-screens/` cover it.

## Other checks

- **Idempotency (item 2):** not observable through the app (H1). The DEBUG seed itself is idempotent
  (second launch: `items 7, occurrences 35 (27 paid, 8 missed), snapshots 5 on 5 days` unchanged). The
  store-level checks exist: `ScheduledMatchTests.sweep` (runs the sweep three times) and
  `ForecastSnapshotTests` (second `takeIfNeeded` the same day returns nil).
- **Watcher (items 3, 4):** each foreign write produced one line
  `[DatabaseChangeWatcher] Database changed by another process; reloading screens` within the run
  (Saldo `patterns.csv`, PKO `all-types.csv`, the PKO gym row, MCP `create_transaction` confirm).
  Note: `log stream` needs `--level info` to show it (the line is `.info`).
- **MCP propose/confirm:** first call returned `status proposed` with a `confirm_token` and changed
  nothing; the second call with the token returned `status done`; transaction count +1.
- **Lock (item 5):** with `-AbacusLockTestPlan "2:lock,5:unlock"` the test app is already locked at
  launch, so the sheet opens behind the lock; the useful order is `"2:unlock,5:lock,8:unlock"`, used for
  `lock-1-sheet-open.png` (sheet open, unlocked), `lock-2-locked-*.png` (no sheet, no toolbar, no
  section title), `lock-3-unlocked-sheet-back.png` (sheet and toolbar back, values kept). The
  "Unlock was cancelled" note on the lock screen comes from the scripted authenticator, not a bug.

## Not checked, and why

- Upcoming section, Bills, All items, item editor (next five dates), suggestions card, dashboard widget —
  not on `main` (H1); prototype `docs/design/N5-upcoming.dc.html` not compared.
- Import wizard review step on screen: `-AbacusImportFile` + `-AbacusSection import` showed the dashboard
  in this run; since no UI code reads `scheduledMatch` (M1), there is no badge to see anyway.
- Real Touch ID / password prompt, synthetic clicks on Unlock under a hidden sheet (no Accessibility
  permission) — as in N7c.

## Gate

`swift test` with `ABACUS_SAMPLES` from `AbacusKit/`: 1334 tests green (Domain 188, FX 40, Import 293, Features 640, MCP 46, Store 127). App build from `main` (unpatched): BUILD SUCCEEDED.
