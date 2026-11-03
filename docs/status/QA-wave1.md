# QA wave 1 — N1, N2, N3, N3b (branch `wp/QA-wave1`)

Date 2026-11-03, built from `main` at `8d51110`. Everything ran on scratch databases in the
session scratch folder with `CFFIXED_USER_HOME` pointing there; the owner's database and its
Backups folder were never opened (not even listed). Counts only; no real data.

## Result

Two bugs found and fixed (both in tools, both with commits below); the rest passed.
Nothing here needs the real database to see, but see "Owner" at the end.

## 1. Build and tests

| Check | Result |
|---|---|
| `swift test` with `ABACUS_SAMPLES`, run 1 | green, 1,175 tests (159 + 39 + 264 + 586 + 46 + 81 in six runs) |
| same, run 2 | green, same counts; the large-data timing test did not flake |
| `xcodebuild … -derivedDataPath build.noindex/qa-dd` (fresh path) | BUILD SUCCEEDED |
| `swift build -c release` `abacus-mcp`, `abacus-import` | both complete (outputs in `AbacusKit/.build`) |
| After the two fixes: `swift test` + app build again | green (1,176), BUILD SUCCEEDED |

## 2. App on scratch databases

- **N1, own database vs demo database.** With `CFFIXED_USER_HOME=<scratch>` the app's own file
  lives under `<scratch>/Library/Application Support/Abacus/`.
  - Own database: first launch wrote `Backups/abacus-<utc>-auto.abacus`; Settings › Data shows
    the Snapshots section (folder path, Back up now, Show in Finder, list with Restore…, text on
    14 days / 6 months, second folder "Not set" with Choose… / disabled Remove, Export/Restore
    backup). A copy with a pending migration (v17 removed) got
    `…-premigration.abacus` on launch and the migration ran.
  - `-AbacusDatabasePath` demo databases (same pending-migration copy included): no
    snapshot anywhere, no `Backups` folder, no files under the scratch home; Settings › Data
    shows only the data folder and Export/Restore (no snapshot section). The migration ran.
  - Code: `AppBootstrap` passes the backup store only for `.appFile`; `AppSession.live(databasePath:)`
    gets no `backupDefaults`. The real Backups folder was not inspected; all runs used the
    scratch home, so nothing could land there.
  - Snapshot file names end `-auto` (docs say "automatic"): cosmetic, left as is.
- **N3b debt caption.** Sample data (debts in EUR, PLN and UAH, display UAH): Debts widget shows
  "≈ total −9 555 ₴" and the caption "−310 € · +110 zł · +5 000 ₴" under it. With the EUR/PLN
  debts settled (UAH only): "Total +5 000 ₴", no caption. As specified.
- **N3 Correction badge.** The sample list has no correction row. A correction booked with
  `abacus-import --balance-correction` showed **no badge** → bug 1 below. After the fix the
  "Correction" badge shows and the footer totals no longer count it.
- **N3 undo refusal message.** Not checked in the app: it needs clicks through the Import wizard
  and the History undo, and this session cannot drive clicks. Covered by
  `TransferCounterpartTests.undoEarlierBatchOfAbsorbed` (green twice); the wizard text is in
  `ImportWizardModel`. Owner: try it once (import two files that create an absorbed transfer,
  undo the earlier import → message "Undo that later import first").
- **Not checked in the app (no click driving):** Back up now, Restore on a scratch DB,
  choosing the second folder. Covered by the store/feature tests (9 + 5 new in N1).
- **`abacus-import --db <scratch> --dry-run`:** Saldo (2 synthetic fixtures) and PKO
  (`--pko-account`) print per-file counts, the database row count is unchanged afterwards.
  A PKO file without an account: see bug 1b.

## 3. MCP over stdio (`abacus-mcp --db <scratch>`)

- initialize (protocol 2025-06-18, `abacus-mcp 0.1.0`), tools/list: 12 read tools, 23 with
  `--enable-writes`. `create_category` without writes: "Unknown tool".
- Reads: `net_worth`, `list_accounts`, `search_transactions`, `debts` return amounts as decimal
  strings with a currency; the two IBANs in the scratch database do not appear in any output.
  On a 5,090-row scratch database `search_transactions` with `limit 1000` returns 200 rows with
  `matching 5090`, `returned 200`, `truncated`.
- Writes (`--enable-writes`, scratch copy): the first call proposes (`confirm_token`, nothing
  changed); a wrong token, and a right token with changed arguments, are refused; the confirm
  executes; the token cannot be reused. One snapshot `…-prewrite.abacus` appeared in
  `MCP-Backups/` beside the scratch file and one line in `MCP/write-log.jsonl`. No snapshot
  went anywhere else.
- Newer schema (extra migration row): reads work with a stderr warning; the write tool answers
  "This database is on a newer schema than this build…; writes are refused" at the proposal
  step, and no `MCP-Backups` folder is created.
- Not done as asked: the staged binary and the client config were not touched.

## Bugs

1. **`abacus-import --balance-correction` did not mark the row as a correction** (N3 badge
   missing; the row counted as an expense in list totals and reports, unlike corrections made
   in the app). Fixed: the tool sets `isBalanceCorrection`. Commit `36632e6`.
   1b. A PKO file without `--pko-account` crashed with an uncaught pipeline error because the
   friendly check ran after the throwing call. Now prints "PKO statement needs --pko-account".
   Same commit. The tool is an executable, so no unit test; verified by running it.
   (The tool still ends with Swift's "Fatal error: Error raised at top level: …" line for any
   `ToolError`: existing style, text is readable, left alone.)
2. **`abacus-mcp` could not open the database when the app is closed.** A read-only SQLite
   connection cannot create `-wal`/`-shm`, so on a WAL database nobody has open the server
   exited with "unable to open database file". My first smoke run only worked because
   `sqlite3` had created those files. This would have hit the owner's real use (MCP client
   started while Abacus is not running). Fixed in `MCPDatabase.openReadOnly`: on that error a
   plain connection is held open so the files exist, then the read-only connection opens.
   Test `readOnlyWithoutWALFiles` fails without the change. Commit `abacus-mcp: open a WAL database that no one has open`.

## Not checked

- Anything on the real database (by rule).
- Back up now / Restore / second-folder choice and the undo-refusal message in the running app.
- A real MCP client end to end (protocol exercised by hand over stdio).
- Pre-migration snapshot on the real database (checked on a scratch copy of the own-database path).

## Requests for shared files

None.

## Owner

Install a new build only if you want the two tool fixes: `abacus-mcp` now works with Abacus
closed (rebuild/stage the binary yourself; I did not touch the staged one), and
`abacus-import --balance-correction` now flags the row. The app itself did not change. Things
only the real database can show: the launch/pre-migration snapshot in the real Backups folder
and the undo-refusal text on real imports.

## Final gate

After both fixes (2026-11-03): `swift test` with `ABACUS_SAMPLES` green, 1,176 tests (1,175 + the new
MCP test); `xcodebuild … -derivedDataPath build.noindex/qa-dd` BUILD SUCCEEDED.
