# QA-fix — tool fixes from the QA-N wave check (L1, L4)

Branch `wp/QA-fix-tools`. Scope: findings L1 and L4 of `docs/status/QA-N.md`. Done.

## L4 — `abacus-import` traps on usage errors (done)

`AbacusKit/Sources/AbacusImportTool/main.swift`: the top-level work moved into `run()`; one
`do/catch` at the top prints `abacus-import: <message>` to stderr and exits **2** for usage errors
(no files/options, bad `--remember-pko` / `--balance-correction`, unknown account name, account in
the wrong currency, PKO file without `--pko-account` and no remembered account) and **1** for
anything else. Messages name arguments and files only; errors other than the tool's own show their
type and localized text. Stdout is flushed first so the error line comes last. Successful output
and the Darwin notification after a write are unchanged.

No unit test: the tool target has no test target and adding one needs a `Package.swift` change
(shared file). Manual check instead, against a scratch DB under `build.noindex/qafix/`:

| Arguments | Exit |
|---|---|
| (none) | 2 |
| PKO fixture without `--pko-account` | 2 |
| `--pko-account Nope` + PKO fixture | 2 |
| `--remember-pko XXX=foo` | 2 |
| `--balance-correction bad` | 2 |
| `--balance-correction Nope=10@2025-01-01` | 2 |
| missing file | 1 |
| Saldo fixture `spec-example.csv` | 0 (same output as before) |

No new `abacus-import-*.ips` in `~/Library/Logs/DiagnosticReports/` (5 before, 5 after; the old
ones are from earlier runs and can be deleted by the owner).

## L1 — snapshot harness hangs with a sheet open (done)

`App/macOS/Shell/WindowSnapshot.swift` (DEBUG only): after the files are written, `quit()` ends
attached sheets, calls `NSApp.terminate`, and if the app is still running 3 s later prints
`WindowSnapshot: still running after terminate; exiting` and calls `exit(0)`. With a SwiftUI
editor sheet open `terminate` still does not quit, so the fallback is what ends those runs.

Verified with `CFFIXED_USER_HOME=<scratch>` and `-AbacusDatabasePath <scratch> -AbacusLoadSampleData YES`
under `build.noindex/qafix/`:
- `-AbacusSection events -AbacusOpenSheet editEvent`: exit 0 after 8 s, `check.png` + `check-sheet.png`.
- `-AbacusSection accounts -AbacusOpenSheet editAccount`: exit 0 after 8 s, both files.
- `-AbacusSection dashboard` (no sheet): exit 0 after 4 s via plain `terminate`.
