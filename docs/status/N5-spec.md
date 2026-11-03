# N5 — Recurring transactions, subscriptions, upcoming bills, forecast (SPEC step)

_Status: **proposed**, for owner review (2026-11-03). Lane `wp/N5-spec`. No app code and no migration
written. The orchestrator folds §2 into `docs/REQUIREMENTS.md` (new §3.8 + §4.1a + §7 edit) and §5 into
`docs/PLAN.md` after approval. Prototypes (synthetic data): `docs/design/N5-upcoming.dc.html`,
`docs/design/N5-forecast.dc.html`._

Sources: `docs/ROADMAP.md` §5 N5 (owner defaults, 2026-11-03), D18/D19 (UUID keys, no cascades for
correctness), D66 (each device a full database, sync covers all data), D68/D71, TA §3.4, §3.7, §4.1,
§6, and the code named below.

## 1. Scope and what changes in the TA

- TA §1 "Out of scope for v1 … recurring transactions" and §7 backlog "recurring/scheduled
  transactions": both lines are removed when this is folded in.
- Remind only (decided): the app **never creates a transaction by itself**. A scheduled item produces
  *expected occurrences*; a real transaction (typed or imported) resolves one.
- The forecast is **today + scheduled items only**. It does not guess everyday spending and it does
  not include the budget (open question Q2).
- Amounts are integer minor units in the **account's currency** (R-CUR-2, R-CUR-3); days are
  `YYYY-MM-DD` strings (`Day`), never `Date`, so time zones and DST cannot move an occurrence.

## 2. Proposed TA text

### 2.1 Scheduled items — `R-REC`

- `R-REC-1` A **scheduled item** is a template plus a schedule. Template: type (expense, income or
  transfer), account (for a transfer: from-account, to-account and the amount received), amount in
  the account's currency, category (expense/income only, same rules as R-TX-3), description
  (payee), optional event, optional note. Schedule: **repeat unit** (day, week, month, year), **every
  N** units (N ≥ 1), **start day**, **end** (never, on a day, or after N occurrences), and **mode**
  (see R-REC-3). An item is *active*, *paused* or *ended*. CRUD from the Upcoming section; deleting an
  item never touches transactions it was matched to.
- `R-REC-2` **Occurrence dates** are computed from the start day only, never from the previous
  occurrence (no drift): weekly keeps the weekday of the start day; monthly keeps its day-of-month,
  and a month without that day uses the **last day of the month** (31st → 30 Nov, 28/29 Feb); an
  item can also be set to **"last day of the month"** explicitly; yearly 29 Feb → 28 Feb in non-leap
  years; every N months/years counts months from the start month. The editor shows the next five
  dates as a preview.
- `R-REC-3` **Mode: remind.** The only mode in v1 (decided 2026-11-03). Each occurrence is *expected*
  until it is **paid** (a real transaction matched or linked), **skipped** by the owner ("not this
  time"), or **missed** (see R-REC-9). The field `mode` is stored (`remind`) so an "auto-create"
  mode can be added later without a migration; no UI offers it now.
- `R-REC-4` **Row actions** on an expected occurrence: *Mark paid* (opens the New transaction editor
  pre-filled from the template; saving it matches the occurrence), *Link existing…* (pick a
  transaction within the match window), *Skip this one*, *Edit item…*. Editing the item changes
  future occurrences only; resolved ones keep the amount and day they were expected with.
- `R-REC-5` **Account rules.** Items on an **archived account** are *paused* automatically with the
  label "Account archived" and leave Upcoming and the forecast (R-ACC-4); unarchiving resumes them. An
  account that has scheduled items cannot change currency (R-ACC-1 extended). Deleting an account
  (R-ACC-5) also asks to delete its items; it is blocked only by transactions, as today. An item
  whose account is later missing is shown as "Account missing" and excluded.

### 2.2 Matching a real transaction — `R-REC-MATCH`

- `R-REC-6` A transaction **matches an expected occurrence** when: same account (a transfer: the
  from-account), same type and flow direction (`Flow.of`), amount within the item's **tolerance**
  (default **5 %**, editable per item; the same rule as `PendingSettlement.amountMatches`), day
  within **±3 days** of the expected day (`FuzzyDuplicate.dayWindow`), and, when both descriptions
  are non-empty, **similar description** (`DescriptionSimilarity.isSimilar`, which already folds case
  and diacritics via `TextFolding`). One transaction resolves at most one occurrence and one
  occurrence takes at most one transaction; when two occurrences compete, the nearer day wins, then
  the nearer amount. A matched occurrence stores the transaction id and the actual day and amount.
- `R-REC-7` **Where matching runs:** (a) import commit, in `AbacusImport/Dedupe/RowAnalyzer` next to
  the pending-hold and duplicate checks: the preview shows a "Matches scheduled: <item> · <day>"
  badge per row and counts them in the summary; nothing changes before the owner confirms; (b) after
  a manual save or edit of a transaction; (c) once at launch for transactions not yet examined
  (covers `abacus-import` and, later, MCP writes; N2). Undoing an import un-matches its occurrences
  (they become expected again). The match **never changes the transaction** (no category, description or
  amount edit), it only records the link; the owner can unlink from the row.
  *Code to reuse:* `AbacusImport/Dedupe/Matching.swift` — `FuzzyDuplicate.dayWindow`,
  `PendingSettlement.amountMatches`, `DescriptionSimilarity`, `Flow`; `Day.distance` for the gap.
  `FuzzyDuplicate.matches` itself is not reused as is (it requires another *source*); a sibling
  `ScheduledMatch` enum in the same file composes the same pieces.

### 2.3 Subscription detection — `R-REC-SUB`

- `R-REC-8` **Suggestions.** The app proposes a scheduled item when it finds **three or more
  expense (or income) transactions** on one account, in one currency, with the **same normalised
  description**, **similar amounts** (all within 10 % of the median) and **regular intervals**.
  Normalised description = `TextFolding.fold` + words without digits (drops card numbers, dates,
  reference ids) + collapsed spaces; two rows share a key when the normalised text is equal.
  Regular = every gap within ±20 % of the median gap, and the median gap is near a known period
  (7 ± 1, 14 ± 2, 30 ± 4 monthly, 91 ± 6 quarterly, 365 ± 10 days); monthly rows also need their
  day-of-month within a 4-day spread. The newest row must be no older than 1.5 periods (an ended
  subscription is not suggested). Rows already matched to an item, refunds, transfers, balance
  corrections and archived accounts are ignored; the last 24 months are examined.
  A suggestion carries: description, account, category (most common), amount (latest), period,
  next expected day (newest + period), confidence (high = ≥ 4 rows with exact-ish amounts, medium
  otherwise) and its evidence rows. **Accept** opens the item editor pre-filled; **Dismiss** hides it
  for good (stored, R-REC-16); **Not now** hides until a new matching row arrives. Suggestions are
  computed on demand, never stored, never create anything alone.
- `R-REC-9` **Missed and overdue.** An expected occurrence whose day is past is *overdue* (shown in red
  at the top of Upcoming, counted in the sidebar badge, and in the forecast on **today**). After a
  grace period (default 14 days, `scheduledGraceDays`) an unresolved occurrence becomes *missed*: it
  stays visible in the accuracy panel, leaves Upcoming and the forecast, and offers "Mark paid / Skip".

### 2.4 Upcoming screen and widget — `R-REC-UP`

- `R-REC-10` **Upcoming** is a sidebar item under Overview (after Events) with a count badge
  (overdue + due in the next 7 days). The page has two tabs, **Bills** and **Forecast**. Bills lists
  expected occurrences for the next 30 days (range selectable: 7 / 30 / 90 days) grouped Overdue,
  Today, This week, Later, each row: tile in the category colour, description, account, repeat label,
  day (relative: "in 3 days"), amount (account currency, income green) with the converted amount in
  the display currency when it differs; actions per R-REC-4. A second view lists **All items**
  (active, paused, ended; search; next date; monthly cost in the display currency) with the
  suggestions card on top ("3 suggestions"). Header totals for the range: money out, money in, net
  (display currency, latest rate; "rates as of <date>" per R-FX-4; amount without a rate left out and
  named, as D27).
- `R-REC-11` **Dashboard widget "Upcoming (30 days)"**: half width (R-HOME-6 widths); next up to six
  occurrences (overdue first), "money out / money in / net" totals in the display currency, "N more…"
  and "Open Upcoming". It takes part in widget reordering. Hidden state: when no item exists it shows
  one line "No scheduled items. Set up your bills in Upcoming." with a button.
- `R-REC-12` **Editor** is a sheet (D55 pattern), primary action bottom-right (R-MGMT-10): fields per
  R-REC-1, a "Repeat" row ("Every [N] [days|weeks|months|years]"), "Last day of the month" checkbox
  when the unit is month, Starts, Ends, tolerance, next-dates preview, and Pause / Delete… at the
  left of the footer. Opening it from a suggestion shows the evidence rows.

### 2.5 Forecast — `R-REC-FC`

- `R-REC-13` **Forecast** (Upcoming › Forecast tab). For every non-archived account the projected
  **balance per day** for the horizon = today's balance (R-ACC-3) + the effects of the expected
  occurrences up to that day, using the same account-effect rule as a real transaction (so liabilities
  and transfers behave as today). **Net worth** per day = the same sum over all accounts converted at
  **today's latest rates for the whole horizon** (R-FX-3; no rate forecast), plus debts that count in
  net worth held at today's value, minus liabilities. The page says "at today's rates" and "rates as
  of <date>".
- `R-REC-14` **Horizon** 30 / 60 / 90 days, **default 90** (owner default; setting
  `forecastHorizonDays`). Selector for the series: Net worth (default) or one account; display
  currency switch as elsewhere (R-HOME-4); the account series is in the account's own currency.
- `R-REC-15` **Warnings.** The page lists the lowest projected point and the first day on which a
  non-liability account's projected balance goes **below zero** ("Main account goes below 0 on 18 Dec,
  −120.00"), with the occurrences that cause it. Threshold fixed at 0 in v1.
- `R-REC-16` **Dismissed suggestions** are remembered (table `suggestionDismissals`, §3) so a
  dismissed pattern is not offered again; "Show dismissed" in the suggestions card restores it.

### 2.6 Forecast snapshots and forecast vs reality — `R-REC-SNAP`

- `R-REC-17` **Daily snapshot.** At launch and whenever the app becomes active, if no snapshot exists
  for today's day and at least one active item exists, the app stores a **forecast snapshot** for the
  full 90-day horizon (always 90, whatever the screen's selector shows): the day, each account's
  starting balance, the rates used, and the expected occurrences with day, account, signed amount
  and item id. A day on which the app was not opened has no snapshot (no back-filling; a past
  forecast cannot be reconstructed truthfully). Matching (R-REC-7c) runs **before** the snapshot so
  today's snapshot starts from resolved occurrences.
- `R-REC-18` **Retention** (default): one snapshot per day for the last **120 days**, then **one per
  week** (the first of each ISO week) up to **2 years**, older ones deleted. Pruning runs after
  taking a snapshot. A snapshot costs a few kilobytes.
- `R-REC-19` **Overlay chart.** The Forecast tab has "Compare with a past forecast": pick a snapshot
  (list: day, "N days ago", forecast end value). The chart then draws **actual** balance or net worth
  from the snapshot day to today (daily end-of-day balances from transactions), the **snapshot's
  forecast** as a dashed line over its whole horizon, today's forecast as a lighter dashed line from
  today, a "today" marker, and the **gap** at today as a shaded band with the amount. Actual and
  forecast are converted at the **snapshot's stored rates** so exchange-rate moves do not appear as a
  gap (a note says so). The caption splits the gap: "scheduled items paid differently: X · everything
  else (unscheduled spending and income): Y" — Y is what the optional "include average spending"
  toggle (later) would have to cover.
- `R-REC-20` **Accuracy panel** (below the chart, scoped to the chosen snapshot's period or "All
  time"): per scheduled item the resolved occurrences with **expected vs actual day** and **expected
  vs actual amount**, differences (+2 days, +3.1 %), counts of paid / skipped / missed, on-time share
  (|Δ day| ≤ 1), average absolute amount deviation; an overall line over all items. When the last
  three paid amounts all differ from the template by more than 2 % the row offers "Update amount to
  X". Data comes from resolved occurrences (`scheduledOccurrences`), not from snapshots, so it works
  even before the first snapshot exists.

### 2.7 Non-functional

- `R-REC-21` Forecast of 90 days for 30 accounts and 100 items computes in < 100 ms (pure function over
  items and balances, nothing per-day in SQL); subscription detection over 20 000 transactions
  < 1 s and runs off the main actor (R-NF-2).
- `R-REC-22` Everything is offline and local (R-NF-1); no notification in v1 beyond the sidebar badge
  and the widget (open question Q5).

## 3. Proposed schema (migration **v18**, reserved)

One migration, append-only, `CREATE TABLE IF NOT EXISTS`, all `STRICT`, single `TEXT` primary key (UUID,
lowercase as SQLiteData binds), **no UNIQUE**, **no CHECK that sync could violate**, foreign keys only
`ON DELETE SET NULL` or `ON DELETE CASCADE` per D19 and none relied on for correctness (the repositories
delete children explicitly first). References to accounts and categories are plain ids when losing the
parent must not delete the row. Header comment to be added in `Schema.swift` like the v17 one. Days are
`YYYY-MM-DD`; money columns are `INTEGER` minor units.

**`scheduledItems`**

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | UUID |
| `type` | TEXT NOT NULL | `expense` / `income` / `transfer` (`TxnType`) |
| `accountID` | TEXT NOT NULL | plain id (from-account for transfers) |
| `toAccountID` | TEXT | transfer only |
| `amountMinor` | INTEGER NOT NULL | positive, account currency |
| `toAmountMinor` | INTEGER | transfer to an account of another currency |
| `categoryID` | TEXT REFERENCES categories ON DELETE SET NULL | expense/income |
| `eventID` | TEXT REFERENCES events ON DELETE SET NULL | |
| `payee` | TEXT NOT NULL DEFAULT '' | description |
| `note` | TEXT NOT NULL DEFAULT '' | |
| `unit` | TEXT NOT NULL | `day` / `week` / `month` / `year` |
| `interval` | INTEGER NOT NULL DEFAULT 1 | every N units, ≥ 1 |
| `startDay` | TEXT NOT NULL | anchor of all dates |
| `lastDayOfMonth` | INTEGER NOT NULL DEFAULT 0 | month unit only |
| `endKind` | TEXT NOT NULL DEFAULT 'never' | `never` / `onDay` / `afterCount` |
| `endDay` | TEXT | |
| `endCount` | INTEGER | |
| `mode` | TEXT NOT NULL DEFAULT 'remind' | only `remind` now (R-REC-3) |
| `tolerancePercent` | INTEGER NOT NULL DEFAULT 5 | R-REC-6 |
| `status` | TEXT NOT NULL DEFAULT 'active' | `active` / `paused` / `ended` |
| `pausedBecause` | TEXT | `owner` / `accountArchived`, so unarchiving resumes only its own pauses |
| `createdAt` | TEXT NOT NULL | |

**`scheduledOccurrences`** — only *resolved* or *missed* occurrences are stored; expected ones are
computed. Identity = (`itemID`, `expectedDay`), guarded by the repository (no UNIQUE).

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | |
| `itemID` | TEXT NOT NULL | plain id; the row survives a deleted item as history ("deleted item" label) |
| `expectedDay` | TEXT NOT NULL | |
| `expectedAmountMinor` | INTEGER NOT NULL | template amount at the time (signed by flow in code, not in the column) |
| `status` | TEXT NOT NULL | `paid` / `skipped` / `missed` |
| `txnID` | TEXT REFERENCES txns ON DELETE SET NULL | the matched transaction; deleting it reverts the occurrence to expected in the repository |
| `actualDay` | TEXT | |
| `actualAmountMinor` | INTEGER | |
| `matchKind` | TEXT | `auto` / `linked` / `typed` (created from the row action) |
| `resolvedAt` | TEXT NOT NULL | |

**`forecastSnapshots`** — header.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | |
| `takenDay` | TEXT NOT NULL | one per day, enforced by the repository; on a sync clash the newest `createdAt` wins when read |
| `horizonDays` | INTEGER NOT NULL | 90 |
| `startBalancesJSON` | TEXT NOT NULL | `{accountID: minor}` plus currencies |
| `ratesJSON` | TEXT NOT NULL | rates to the base used for conversion, `{"asOf": day, "EUR": …}` |
| `createdAt` | TEXT NOT NULL | |

**`forecastSnapshotItems`** — the expected occurrences of that forecast.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | |
| `snapshotID` | TEXT NOT NULL REFERENCES forecastSnapshots ON DELETE CASCADE | repository also deletes explicitly |
| `itemID` | TEXT | plain id, may outlive the item |
| `day` | TEXT NOT NULL | |
| `accountID` | TEXT NOT NULL | |
| `toAccountID` | TEXT | |
| `amountMinor` | INTEGER NOT NULL | signed effect on `accountID` |
| `toAmountMinor` | INTEGER | signed effect on `toAccountID` |

**`suggestionDismissals`**: `id` PK, `accountID` TEXT, `key` TEXT (normalised description + currency), `dismissedAt` TEXT.

Indexes: `scheduledOccurrences(itemID)`, `scheduledOccurrences(txnID)`, `forecastSnapshotItems(snapshotID)`,
`forecastSnapshots(takenDay)`, `scheduledItems(accountID)`. Domain: `@Table` structs in
`AbacusDomain/Model/Entities.swift` (ScheduledItem, ScheduledOccurrence, ForecastSnapshot,
ForecastSnapshotItem, SuggestionDismissal), enums `ScheduleUnit`, `OccurrenceStatus`; pure logic in
`AbacusDomain/Calc/` (`Schedule`, `ForecastEngine`, `SubscriptionDetector`); repositories in
`AbacusStore/Repositories/`.

Why JSON for the start balances and rates, rows for the items: balances and rates are only ever read
whole, the items are queried per item for the accuracy panel and per day for the overlay. `ratesJSON`
makes an old snapshot reproducible. A snapshot is derived data; losing one costs only history. The sync
default (Q6) is "sync like everything else (D66)", read-side dedupe by `takenDay`.

## 4. Edge cases

| Case | Behaviour |
|---|---|
| Monthly on the 31st | Last day of shorter months; 30 → 28/29 Feb; the next month returns to the 31st (R-REC-2) |
| "Last day of the month" | 31 Oct, 30 Nov, 28 Feb… |
| Yearly 29 Feb | 28 Feb in non-leap years |
| Every 2 months from 31 Jan | 31 Jan, 31 Mar (not 28 Feb + 2 months drift), 31 May… |
| Weekly across a DST change | Day strings only; no 23/25-hour arithmetic. `Day` ↔ `Calendar` uses the device calendar once, to turn `Txn.occurredAt` into a day |
| Device time zone changes | "Today" is recomputed from the current calendar; stored days do not move. A snapshot keeps its `takenDay` |
| Item starts in the past | First expected day is the first occurrence ≥ start; occurrences before today with no match are **not** generated as overdue — only those within the grace period (R-REC-9). Older ones simply do not exist |
| End reached | Item becomes `ended` after the last occurrence is resolved; stays in All items |
| Multi-currency | Item amount is in the account's currency, so matching compares like with like. A subscription billed in USD on a PLN card is entered as the PLN amount it usually shows (tolerance 5 % may be raised to cover rate drift; "Update amount to X" corrects it). The forecast converts at today's rates, flat |
| Transfer between currencies | `amountMinor` leaves the from-account, `toAmountMinor` arrives; if empty, the NBU rate of today estimates it (as `isEstimatedTransferAmount`, D64) and the forecast labels it estimated |
| Archived account | Items paused (R-REC-5), excluded from Upcoming, forecast and snapshots; archived accounts are not in net worth (R-ACC-4) |
| Account unarchived | `pausedBecause = accountArchived` items resume; occurrences of the gap period are not generated as overdue (grace period) |
| Liability account (credit card) | Same account-effect function as real transactions; a card payment scheduled as a transfer from the main account reduces the liability |
| Two items for one payment | Matching never lets one transaction resolve two occurrences; the nearer day wins |
| Same-day equal items (two 49 PLN subscriptions) | Description similarity decides; if both match equally the first by item `createdAt` |
| Matched transaction deleted | Occurrence returns to expected (or missed, if past grace) |
| Matched transaction edited out of tolerance | Link kept (the owner or the import chose it); the accuracy panel shows the deviation |
| Import undone | Occurrences matched by that batch return to expected |
| Pending PKO hold matched, later settled | The link follows the transaction; amount/day in the occurrence are refreshed on settle |
| Refund of a paid item | Refunds (R-TX-4) are never matched |
| Balance-correction rows | Never matched, never part of suggestions |
| No item | No snapshot; widget shows the empty state; the Forecast tab says there is nothing to project |
| Rates missing for a currency | Net worth forecast leaves it out and names it (D27); account series unaffected |
| App not opened for weeks | No back-filled snapshots; overdue items older than grace become missed on next launch |
| Backup/restore (N1, R-SET-2) | New tables are in the file like any other; restoring an older backup simply has older snapshots |
| Debts | Held at today's value in the forecast; no scheduled debt payments in v1 (a transfer to a debt account can be scheduled like any transfer) |

## 5. Test ideas per ID (Swift Testing, synthetic data, tag by ID per R-NF-5)

- **R-REC-1** repository round trip of every field; paused/ended filtering; deleting an item keeps its
  occurrences and matched transactions.
- **R-REC-2** table-driven: monthly 31st over 12 months incl. leap Feb; "last day"; yearly 29 Feb over 8
  years; every-2-months from 31 Jan; weekly over a spring and an autumn DST date in `Europe/Warsaw` and
  `America/New_York` calendars (days must stay 7 apart); end by day and by count; start in the past; N = 1…
  property test: occurrences strictly increasing, anchored, count = formula.
- **R-REC-3** `mode` stored as `remind`; no code path creates a `Txn` (test asserts txn count unchanged
  after launch-time processing).
- **R-REC-4** pre-filled editor model from a template; "Link existing" candidates restricted to the
  window; skip excludes from forecast and totals; editing an item leaves resolved occurrences alone.
- **R-REC-5** archive pauses with the right `pausedBecause`; unarchive resumes only those; currency
  change blocked; account delete asks and removes items.
- **R-REC-6** amount ±5 %/±6 %, day ±3/±4, other account, other direction, empty description, dissimilar
  description, two occurrences competing, one transaction two items; tolerance override.
- **R-REC-7** import preview marks the badge and counts but writes nothing before confirm; commit
  writes the link; undo import reverts; launch-time sweep is idempotent; manual save matches; the
  matched transaction is byte-identical afterwards.
- **R-REC-8** detector table: 3 monthly rows → suggestion; 2 rows → none; irregular gaps → none; amount
  spread > 10 % → none; digits/dates in descriptions normalise to one key (`CARD *1234`); two accounts
  → two suggestions; ended pattern (newest > 1.5 periods) → none; already matched → none; yearly with 3
  rows; dismissed → none; performance at 20 000 rows.
- **R-REC-9** overdue counting in forecast on today; becomes missed after the grace days; configurable.
- **R-REC-10/11** view-model tests: grouping, relative day labels, totals in display currency with a
  missing rate named; empty state; badge count.
- **R-REC-12** next-dates preview equals `Schedule.occurrences`; validation (N ≥ 1, end ≥ start, transfer
  accounts differ).
- **R-REC-13** balances: no items → flat line equal to current balance; one monthly item; transfer moves
  money between two accounts and leaves net worth flat in one currency; liabilities; flat rates;
  archived excluded; equals a replay where the same items are created as real transactions (oracle test).
- **R-REC-14** horizon 30/60/90 truncation; default 90.
- **R-REC-15** first-below-zero day and causing items; none when never below.
- **R-REC-16** dismissal persists per (account, key); restore.
- **R-REC-17** one snapshot per day (second call no-op); none without active items; start balances and
  items equal the forecast at that moment; matching ran first; sync-style duplicate for one day
  resolves to the newest on read.
- **R-REC-18** retention with a fake clock: 120 daily, weekly to 2 years, older gone; items deleted with
  the header.
- **R-REC-19** overlay series: actual from daily balances equals the balance calculators; both lines
  converted at the snapshot's rates (change today's rate → overlay unchanged); gap equals actual −
  forecast at today; split sums to the gap; snapshot older than data → clamped.
- **R-REC-20** per item expected-vs-actual deltas, on-time share, "Update amount" after three drifting
  payments; scope by snapshot period vs all time; works with zero snapshots.
- **R-REC-21** timing tests with the large-data fixture (robust against contention, see N3).
- Cross-cutting: migration v18 on a v17 database keeps every table; schema rules test (no UNIQUE, only
  CASCADE/SET NULL) if one exists for earlier migrations.

## 6. Proposed work-package split (after approval)

All four lanes branch from `main` after the TA is folded in; the orchestrator does migration v18 and the
entities first (shared contract files), as in PLAN.md.

| WP | Content | Owned paths (proposed) |
|---|---|---|
| **N5a Core** | Migration v18, entities, `Schedule`, `ScheduledMatch`, `SubscriptionDetector`, repositories (items, occurrences, dismissals), RowAnalyzer hook, launch sweep, tests R-REC-1…9, 16 | `AbacusDomain/Calc/Schedule*`, `AbacusDomain/Model/Entities.swift` (orchestrator), `AbacusStore/Repositories/Scheduled*`, `AbacusImport/Dedupe/Matching.swift` + `RowAnalyzer.swift` hook |
| **N5b Upcoming UI** | Sidebar item + badge, Bills tab, All items, suggestions card, editor sheet, dashboard widget; built against approved `N5-upcoming` and the widget of `N5-forecast`; after N5a | `AbacusFeatures/Upcoming/`, widget file under `AbacusFeatures/Dashboard/` (shell/sidebar edits by the orchestrator, as D50) |
| **N5c Forecast engine + snapshots** | `ForecastEngine`, daily balance series, snapshot take/prune/read, tests R-REC-13…15, 17, 18 | `AbacusDomain/Calc/Forecast*`, `AbacusStore/Repositories/ForecastSnapshotRepository.swift` |
| **N5d Forecast UI** | Forecast tab, overlay chart, accuracy panel; after N5b and N5c | `AbacusFeatures/Forecast/` |

N5a and N5c can run in parallel (disjoint paths; N5c needs the entity and `Schedule` signatures from
the orchestrator's contract commit); N5b follows N5a; N5d follows N5b and N5c. Interplay: N6
(reconciliation) adds a column on `txns` in v19 and does not touch these tables; N2 (MCP) can later
expose `upcoming` and `forecast` as read tools; N1 backups need nothing special.

## 7. Open questions (each with a proposed default)

| # | Question | Proposed default |
|---|----------|------------------|
| Q1 | Forecast horizon | **90 days** stored in snapshots; screen selector 30/60/90, default 90 |
| Q2 | Is the budget part of the forecast? | **No.** Scheduled items only (owner's rule). The budget's unspent remainder can be shown as a separate hint line ("budget still open this month: X") if the owner wants it, not as part of the line |
| Q3 | Snapshot retention | Daily for 120 days, then weekly up to 2 years, then deleted |
| Q4 | Grace period before an unresolved occurrence is "missed" | 14 days |
| Q5 | Notifications (desktop banner for a bill due tomorrow) | None in v1; sidebar badge and widget only (D20: banners are the only possible kind, so an opt-in setting can follow later) |
| Q6 | Do snapshots sync (D66)? | Yes like all data; duplicates for one day resolved on read. Alternative: keep them device-local like `fxRates` |
| Q7 | Transfers as scheduled items (savings top-up, card payment) | **Yes**, included |
| Q8 | Income items (salary) | **Yes**, included; matched like expenses |
| Q9 | Amount tolerance default | 5 % (same as pending-hold settling), editable per item |
| Q10 | Where the forecast lives | Second tab of **Upcoming** (Bills · Forecast), not a separate sidebar item; the widget links to Bills |
| Q11 | Subscription periods offered | weekly, biweekly, monthly, quarterly, yearly; no "every 4 weeks" detection (can be set by hand) |
| Q12 | Overdue items in the forecast | Counted on **today** until resolved or missed |
| Q13 | Gap split caption (scheduled differences vs everything else) | Included (cheap, answers the "include average spending" question) |

## 8. Prototype notes (what the owner should look at)

- `N5-upcoming.dc.html`: sidebar with the new **Upcoming** item and badge; Bills tab with grouped
  occurrences and row actions; "Simulate import" strip shows an expected row turning into *Paid ·
  matched* (R-REC-7); suggestions card with evidence rows; All items tab; the item editor sheet with
  repeat, month-end option and next-dates preview.
- `N5-forecast.dc.html`: dashboard with the **Upcoming (30 days)** widget; Forecast tab with horizon,
  series and currency controls, warning line, **overlay of a chosen past snapshot** over actual, gap
  band and split, and the **accuracy panel** with expandable per-item rows.
- Both are standalone files (inline script, no support runtime), synthetic data only (invented
  accounts and merchants); `Today` in them is 3 Nov 2026.
