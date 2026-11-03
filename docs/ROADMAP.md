# Roadmap — ideas, owner decisions, next work

_Written 2026-11-03 (orchestrator) from a discussion with the owner. Nothing here is a requirement
yet: the TA (`REQUIREMENTS.md`) changes only after the owner approves a work item below.
Do not start a work item whose status is not **approved**._

Terms: **TA** = tech assignment (`REQUIREMENTS.md`). **CLI** = a command-line program (a terminal
command). **Headless** = runs without a window; `abacus-import` is one (same import pipeline and
database as the app, counts only). **MCP** = Model Context Protocol, a standard that lets an AI chat
client call typed tools; here a local, read-only server over the app database.

## 1. Owner decisions (2026-11-03)

- **iOS app: postponed.** Focus stays on improving the macOS app. When it is built it is a
  **mirror of the macOS app**: balances, dashboard, everything, not a capture-only app.
- **Each app is independent.** macOS and iOS each keep a full database (their own source of truth)
  and must work alone. Sync covers **all** data (transactions, accounts, categories, rules, budgets,
  debts, events, settings that belong to the data), not only transactions.
- **Sync experience wanted:** press one button on either device; everything then happens without
  further manual steps. Batch sync is fine, live sync is not required.
- **MCP:** local server with read tools and write tools (transactions, categories, accounts, import
  undo and move; see N2). A CLI may be added later if scripting is wanted.
- **Visual check:** the owner checked the current app (1.6.2) visually on 2026-11-03: fine.
- **Quick actions (N8) are skipped for the next iteration.**
- **Order of next work:** N1 backups + N3 stabilisation, then N2 MCP, then recurring/forecast,
  reconciliation, app lock (run in parallel where files do not overlap). N8 is deferred.

## 2. Sync design notes (for when iOS starts)

Two independently writable full copies is multi-master replication: it needs conflict rules and
version rules. Two workable options:

| | A. CloudKit through SQLiteData `SyncEngine` | B. Own encrypted change log in a shared folder |
|---|---|---|
| Account | Paid Apple Developer Program (about 99 USD/year) | None for the app; free-signed iPhone builds expire every 7 days |
| Automatic | Yes, background push/pull | Mac can publish on every save; iPhone syncs on open or on the button |
| Build effort | Low: engine exists, schema rules already followed (D6, D18, D19) | High: change log, per-row timestamps, tombstones, merge, repair of broken references |
| Versions | Additive CloudKit schema, deployed to Production; old app versions ignore new fields | Each log entry carries a schema version; an older app refuses newer entries and asks for an update; a manifest holds the minimum compatible version |
| Security | Private database of the user's iCloud account; Apple holds keys unless Advanced Data Protection is on (verify before relying on it) | Files encrypted on the device (AES-GCM, key from a passphrase kept in the Keychain), so the transport only sees ciphertext |
| Vendor lock | Apple | None: iCloud Drive, a private Git repository, USB all work |

- **Version problem, in short:** every database change is tagged with its schema version. A device
  applies only changes it understands; newer changes wait until the app is updated. The Mac app is
  updated first (the owner controls both).
- **GitHub as transport:** possible with option B and client-side encryption (then a leaked token or a
  public repository by mistake exposes only ciphertext). Git is still a poor fit: binary data,
  credentials on the phone, and merges that do not understand the data. Not recommended.
- **Free alternative without sync:** a file exchanged by AirDrop or the Files app (new transactions
  one way, a reference snapshot the other way) through the import pipeline. Manual, so it does not
  meet the "one button" wish; kept only as a fallback.
- **Recommendation:** option A when iOS starts (cheapest in effort; the fee is small next to the
  work option B costs). Revisit if the owner does not want a paid account.
- **Not synced by design:** the exchange-rate cache (each device fetches its own), the data-folder
  setting and window state. Restore-from-backup needs a defined meaning once sync runs.
- **Owner prerequisites for iOS with option A:** join the Developer Program; register the Mac and
  iPhone bundle IDs and one iCloud container; switch the Mac app from ad-hoc to Developer ID signing
  with a provisioning profile that includes the container, and notarize the DMG; deploy the
  CloudKit schema to Production; an iPhone on iOS 26 signed into the same iCloud account; back up
  the real database before the first sync and try a scratch container first. Install on the phone
  from Xcode (valid a year with the paid team) or through TestFlight internal testing.
- **iOS scope:** same as macOS. Plan it as slices (dashboard and transactions, then editor, budget,
  debts, then management and import) and design the iPhone screens as prototypes first (TA §6).
- **Before sync:** new tables follow D18/D19 (UUID keys, no cascades for correctness), so adding
  sync later needs no rewrite.

## 3. Investments (Interactive Brokers), not scheduled

TA currently lists investments as out of scope; the owner reopens it by approving a TA change.

- **Import IB Flex Query files** (positions, trades, cash flows, dividends, fees); skip the live API
  (needs a running gateway/session, clashes with offline-first R-NF-1). A parser is one more
  `ImportParser` with the same dedupe, preview and undo. A "fetch with token" button can come later
  (token in the Keychain). Flex queries cover at most 365 days per range.
- **Steps:** I1 importer + tables (security, position or lot, trade) · I2 investment account value
  feeds net worth, holdings screen, dashboard widget · I3 price refresh (separate from FX, off by
  default; Flex carries the report-date close) · I4 performance (realised/unrealised P&L,
  dividends, fees, allocation, money-weighted return).
- **Open:** price source (Yahoo unofficial endpoints are fragile; Stooq or a keyed free tier);
  currencies beyond the four (D24); a realised-gains export for tax (method to be checked by an
  accountant).
- **Owner does:** enable the Flex Web Service, create the saved queries, generate a token; keep
  exports and the token out of git.

## 4. MCP and CLI

MCP and CLI are not rivals; both are thin shells over a query layer in `AbacusKit`. Build the
query layer and the MCP server first (works in a chat client, reads first, writes behind safeguards); a CLI
with JSON output is a cheap by-product if scripting is wanted. Privacy: whatever a tool returns
goes to the AI client, which touches the "no telemetry" principle, so it is opt-in, local (stdio),
aggregate-first for reads, and every write is confirmed and logged.

## 5. Next work items and readiness

Status values: `proposed` (defaults below await the owner's approval), `approved`, `in progress`,
`done`. Sizes as in `PLAN.md`. Lane ids use the series **N**.

| Id | Item | Size | Needs | Status |
|----|------|------|-------|--------|
| N1 | Automatic backups and pre-migration snapshot | M | defaults below | proposed |
| N2 | Local MCP server (read tools, then write tools) | M | defaults below; needs N1's snapshot API for writes | approved 2026-11-03 |
| N3 | Stabilisation pass | M | scope below | proposed |
| N4 | Database encryption research (document only, no code) | S | none | proposed |
| N5 | Recurring transactions, subscription detection, upcoming bills, cash-flow forecast | L | TA text + approved prototypes; migration v18 reserved | approved 2026-11-03 (spec step first) |
| N6 | Reconciliation: cleared flag, statement-balance check, balance-continuity detection | M | TA text + approved prototypes; migration v19 reserved | approved 2026-11-03 (spec step first) |
| N7 | App lock (Touch ID / password) | S | TA text; encryption follows N4 | approved 2026-11-03 (spec step first) |
| N8 | Quick actions: ⌘K command palette, menu-bar quick add, Shortcuts / App Intents "add expense" | M | TA text + approved prototypes | deferred (owner, 2026-11-03) |

Readiness: N1, N2, N3, N4 can start as soon as the owner approves them (nothing blocks them in the
code). N5 to N8 first need requirements text and prototypes (design process, TA §6; no UI is built
against an unapproved screen), so each starts with a short spec step the owner reviews.

### Proposed defaults (owner: approve or change)

**N1 Backups.** Today only a manual export/restore exists (`AbacusStore/Repositories/Backup.swift`,
R-SET-2) and migrations run on open (`AbacusDatabase.open`) with no copy taken.
- Snapshot into `~/Library/Application Support/Abacus/Backups/` on launch when the newest is older
  than 24 h; plus a snapshot **before any migration runs** (kept separately).
- Retention: 14 daily, 6 monthly, the last 3 pre-migration snapshots.
- Optional second folder chosen by the owner (iCloud Drive or an external disk), because a copy on
  the same disk is not disaster recovery.
- Settings: list of snapshots, Restore (existing all-or-nothing restore), Back up now, folder.
- Unencrypted for now; revisit after N4/N7.

**N2 MCP.** Stdio server `abacus-mcp` in `AbacusKit`.
- Default: the app database; a flag points at a scratch database. Read tools use a read-only
  connection.
- Tools: net worth, spending by category and month, budget status, search transactions (filters,
  capped at 200 rows), accounts, debts, cash flow over a range, uncategorised rows, rates.
- Amounts as decimal strings with currency. Descriptions included; IBANs and account numbers are
  not. Tested on synthetic data only.
- **Write tools (owner, 2026-11-03):** create/read/update/delete transactions (all types, attached
  records, refund link, event); create/read/update/delete categories; create/read/update accounts
  and archive (no delete of accounts); undo an import; move an import to another account. Further
  candidates awaiting the owner: bulk re-categorise, rules create/update/apply, events and budget
  limits, debt links and counterparts, import a file (preview first), back up now.
- **Safeguards (proposed):** writes go through the same repositories as the app, so its rules hold
  (for example an account with transactions is archived, not deleted); a propose-then-confirm step
  per write; a cap on rows per call; a backup snapshot (N1) before a session's first write; every
  write logged; no restore-from-backup and no settings changes through MCP. The lane must check how
  the running app notices changes written by another process (proposed design next).
- **Cross-process changes (proposed):** the database stays shared. (1) The app polls SQLite's
  `PRAGMA data_version` about once a second; it changes whenever another connection wrote, so the
  app then reloads its screens (this also covers `abacus-import`). (2) After a write the MCP
  server posts a Darwin notification for an instant refresh. (3) The app also refreshes when it
  becomes active. Writes use short transactions and a busy timeout (WAL allows readers meanwhile).
  The MCP server refuses to write when the database is on a newer schema than its own build. A
  sheet open on a record that MCP changes meanwhile warns before saving over it. A single-writer
  design (MCP asks the running app to perform the write over a local channel) is a heavier
  alternative if the above proves flaky.
- First task: check whether the official Swift MCP SDK fits Swift 6.2 / macOS 26; otherwise a small
  hand-written JSON-RPC over stdio. Setup snippet for an AI client goes into the README.

**N3 Stabilisation.** Scope from `STATUS.md` open items: no badge for correction transactions;
headless `abacus-import` does not link refunds or offer counterparts; undoing the batch that
created an absorbed transaction deletes the transfer; the large-data timing test flakes in a full
parallel run; (the visual check of the current app was done by the owner on 2026-11-03: fine);
owner questions still open (debt filter date range, per-currency caption); soak + hang watch run.
New findings from the owner are added to this list.

**N4 Encryption research.** Output `docs/status/N4.md`: options (SQLCipher with GRDB/SQLiteData,
relying on FileVault, field-level), compatibility with SQLiteData and CloudKit sync, effect on
backups and MCP, and the key problem: a Keychain item guarded by an **ad-hoc signed** app changes
identity on every rebuild, so the system keeps asking for access; Developer ID signing would fix
that. Recommendation, no code.

**N5 Recurring and forecast.**
- A scheduled item = template (type, account, amount, category, description, event) + schedule
  (weekly, monthly, yearly, every N, end). Default mode: **remind**, not auto-create.
- A real imported or typed transaction matching an expected occurrence (same account, amount within
  a tolerance, about three days) marks it paid, using the existing fuzzy-match code.
- Subscription detection: three or more transactions with the same normalised description and a
  similar amount at regular intervals become **suggestions** the owner confirms.
- Screens: an Upcoming section in the sidebar and a dashboard widget "Upcoming (30 days)".
- Forecast: projected account balances and net worth for 90 days = today + scheduled items only
  (no guessing of everyday spending); an "include average spending" toggle can come later.
- **Forecast vs reality (owner, 2026-11-03):** the app saves a forecast snapshot (projected
  balances and expected items for the next 90 days) about once a day (new table, migration v18).
  A chart overlays a chosen past snapshot on the actual balance or net worth, and a small
  accuracy panel lists, per scheduled item, expected vs actual date and amount. The gap between the
  lines is the everyday spending the forecast ignores, which also shows whether the later "include
  average spending" toggle is worth building.
- Decided: remind only. Open: forecast horizon (default 90 days), whether the budget is part of
  the forecast, how long snapshots are kept.

**N6 Reconciliation.**
- `cleared` flag on transactions; per-account Reconcile mode: enter the statement date and closing
  balance, see the difference against the cleared sum, mark rows cleared.
- Rows from a bank file count as cleared (a booked bank row cannot disappear); imported Saldo rows
  count as cleared too (the owner is migrating from Saldo; an import never deletes anything).
  Hand-typed rows start uncleared and become cleared when a bank row matches them (existing fuzzy
  match) or when ticked in Reconcile. A cash account is reconciled against a counted amount.
- **Stale pending holds (owner, 2026-11-03):** PKO holds vanish from later exports
  (`docs/import/pko-format.md`); one that never settles stays pending forever today. At import, a
  pending hold that the new file covers (value date at least a few days older than the file's last
  booked day) and that matched no row is raised in the preview as "pending payment not in the bank
  file" and needs a manual decision: keep, delete, or edit. It also shows whether such cases occur
  at all. Pending holds stay uncleared until settled.
- Balance-continuity detection at import: compare each row's running balance with the next row (PKO
  "Saldo po transakcji") and warn on a gap; this was proposed earlier in `docs/status/C41.md`.
- Decided: bank-file rows auto-clear on import.

**N7 App lock.** System authentication (Touch ID with password fallback). Locks at launch, after
an idle time set in Settings (default 5 minutes), and on sleep or screen lock; content hidden while locked. **Off by
default**, switch in Settings. Database encryption is separate and decided after N4.

**N8 Quick actions (deferred to a later iteration, 2026-11-03).** In order: ⌘K command palette (jump to a section, account or category; run New
transaction, Import file, Refresh rates, Back up now; search transactions) → menu-bar quick add
(amount, account, category, description; reuses the editor model) → Shortcuts / App Intents
"Add expense" and "Get balance" (check that intents work from an ad-hoc signed build).

## 6. Other ideas (backlog)

FX effect on net worth (how much of a change is currency, not money) · CSV/PDF export · goals and
sinking funds · budget rollover · tags · receipts/attachments · more bank formats (Monobank,
Revolut CSV) · multi-file import and an "Uncategorised" card in the import wizard · a visual
verification checklist per release · merge the "card" and "bank account" kinds · SQL aggregates
beyond about 20k transactions (S1).
