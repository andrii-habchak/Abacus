# N10 — Salary thresholds, raises and "salary vs expectation" chart: spec (proposed TA text)

State: spec for owner review (no code, no migration written)   ·   Branch: wp/N10-salary-spec   ·   Updated: 2026-11-17

New roadmap item, not yet in `docs/ROADMAP.md` (the id N10 is a proposal; the orchestrator assigns it and
needs the owner's **approved** per D68 before any lane starts). Requirements 1–5 below were confirmed by the
owner; everything marked **Decision** or **Q** is open. Proposed TA text uses new `R-SAL-…` IDs; the
orchestrator folds it into `docs/REQUIREMENTS.md` (new §4.10, change-log row) after approval. Examples are
synthetic.

Facts used from the code (checked 2026-11-17 on `main` 84cbcc1, release 1.7.0 unreleased):

- Migrations end at **v19** (`AbacusStore/Migrations/Schema.swift`; v18 recurring, v19 cleared). The next free
  number is **v20**. Migrations are append-only, CloudKit-safe (STRICT, single TEXT primary key, no UNIQUE,
  `ON DELETE` only CASCADE / SET NULL, `IF NOT EXISTS`).
- N5 merged only its **first slice**: tables + entities (`AbacusDomain/Model/Scheduled.swift`) + pure logic
  (`Schedule`, `ForecastEngine`, `SubscriptionDetector`). **No repository, no matching, no launch sweep, no
  Upcoming UI exists yet** (`docs/status/N5.md` "Left to do" steps 1–8). So today nothing creates or reads a
  `ScheduledItem` or an occurrence at runtime.
- `ScheduledItem` has no name and no currency of its own: the name is `payee` (also the description used by
  matching, `R-REC-6`); the currency is the **account's** currency (`R-REC-1`, "amount in the account's
  currency"), and `R-REC-5` blocks changing an account's currency while it has items. It has `type`
  (income), `categoryID`, `unit`/`interval`, `amountMinor`, `status` (active/paused/ended), no colour.
- A paid occurrence stores `txnID`, `actualDay`, `actualAmountMinor` (`ScheduledOccurrence`); matching is
  one transaction per occurrence within ±3 days and ±`tolerancePercent` (5 % default).
- Default categories seed an income parent **"Salary"** (`DefaultCategories.swift`); categories are
  editable (rename, archive, delete), so the name is not a stable key.
- Dashboard: `DashboardModel` loads accounts, categories, all transactions and the rates once and recomputes
  per widget; widgets are the `DashboardWidget` enum (`DashboardLayout.swift`, raw values stored in the
  `dashboardLayout` setting, unknown/new ids are handled forgivingly); the display currency is
  `SettingKey.displayCurrency` and the switch changes `DashboardModel.displayCurrency` (`R-HOME-4`). Charts
  are Swift Charts in `App/macOS/Dashboard/*Card.swift` (`DashboardIncomeExpensesCard` is the closest
  sibling: 12 months ending at the selected month).
- Currency conversion (`AbacusDomain/Protocols/FX.swift`, `AbacusFX/Conversion/RateTable.swift`): a
  `CurrencyConverter` gives `rate(from:to:on:)` (weekend/holiday → earlier day; manual overrides win) and
  `latestRate`. Amounts without a rate are left out and reported in `DashboardMissingRates` (D27), never
  converted at 1. Four currencies only (UAH, PLN, EUR, USD, D24).

## 1. Does "a salary = one recurring income item" fit?

**Mostly yes; three gaps and their closest fit.**

| Requirement | Fit | Gap and proposal |
|---|---|---|
| One recurring income entity, Salary category | `ScheduledItem` with `type = income`, `categoryID` in the Salary group | Nothing marks an item as *a salary*, and the category name is not a stable key. **Proposal:** a new table `salaries` (§4) marks an item as a salary; creating one requires `type = income`, a category (suggested: the "Salary" income category; any income category is accepted, **Q1**), and a **monthly schedule** (`unit = month`, `interval = 1`). Weekly or bi-weekly pay does not fit a *per month* threshold (**Q2**: v1 monthly only). |
| Stable name | `payee` | Fits as the display name, but `payee` is also the matching description (`R-REC-6`): renaming a salary can stop its next payment from matching until the bank's description is similar again. Accept (rename is rare); the salary's identity is its item id, not the name. |
| Stable currency | account currency | Fits: the item's currency cannot change while the item exists (`R-REC-5`). Switching to another currency means a new salary (new item), see Q6. |
| Actual pay including bonuses | occurrence ↔ transaction link | **Gap.** An occurrence links exactly one transaction within ±5 % of the template. A bonus paid separately never matches (it is far outside the tolerance and the occurrence is already taken); a salary + bonus paid as one transfer may fail the tolerance too. **Proposal:** the salary's *actual pay* for a month = transactions linked by occurrences **plus** transactions the owner links explicitly as extra pay (table `salaryExtraLinks`, §4; action "Count as pay of <salary>" on an income transaction, any amount, any account). Tolerance is not changed. |
| Expected amount | `amountMinor` (forecast template) | Two numbers now exist: the item's template amount (forecast) and the threshold (expectation). **Q5**: should a new threshold also update the item's template amount? Default proposed: offer a checkbox "Also update the scheduled amount" (ticked when the threshold currency equals the account currency), never silent. |

**Hard dependency:** the chart needs N5 steps 1 (repositories), 2 (matching) and 3 (launch sweep), otherwise no
occurrence is ever paid and a salary shows nothing but extra links. This spec therefore starts after those
merge (or the lane includes them, **Q9**). The Upcoming UI (N5b) is *not* required: the salary editor can be a
sheet from the dashboard widget (**Q7**).

## 2. Requirements (proposed TA text)

### 2.1 Salaries and thresholds — `R-SAL-1…4`

- `R-SAL-1` **Salary.** A salary is a scheduled item (`R-REC-1`) of type income with a monthly schedule,
  marked as a salary. It has a name (the item's description), a currency (its account's currency), a colour
  (distinct from the other salaries, picked from `ColorPalette` when created, editable) and its pay-day
  (the item's schedule). A salary is created from a new "Salary" toggle in the scheduled-item editor, or
  by marking an existing income item. A salary that ends (item ended or paused) keeps its history and its bars.
  Deleting the item asks "This also deletes its thresholds, raise history and extra-pay links" (the
  transactions are never touched, `R-REC-1`).
- `R-SAL-2` **Threshold.** A salary has a history of thresholds, each: amount (positive, minor units),
  currency (any of the four; default the previous threshold's currency, else the account currency), **start
  day**. There is **no stored end day**: a threshold applies from its start day until the day before the next
  threshold's start day; the newest one is open-ended. Setting a new threshold is therefore exactly "close the
  previous one the day before, open the new one open-ended" without a second write that could disagree. The
  change from one threshold to the next is a **raise event** (§2.4).
  - Validation: the new start day must be **later than the newest start day** (append-only; backdating before
    it is done by editing a row). Two thresholds cannot share a start day. Edit and delete exist for
    corrections: editing keeps the order of start days; deleting the newest threshold re-opens the previous one.
  - The first threshold may start at any day, also before the salary's own start day; before the first
    threshold there is no expectation (§2.3).
  - A start day in the future is allowed (a raise agreed for next month); it shows as "from <day>" in the history
    and starts to count when its month is reached.
- `R-SAL-3` **Which threshold applies to a month — Decision D1.** Owner default: *the threshold active on the
  last day of the month*. **Proposed better rule:** *the threshold active on the salary's **pay day** of that
  month* (the actual payment day of the month's main payment if one is linked, else the occurrence's
  expected day, else the last day). Why: a raise that starts on 20 October on a salary paid on the 10th does not
  apply to the October payment; with the last-day rule October compares the old pay with the new, higher
  threshold and shows a **false shortfall** (4,000 paid vs 4,400 expected, +10 %), and the raise then "shows" a
  month early. With the pay-day rule October is judged by 4,000 and November by 4,400. For a raise starting on or
  before the pay day (e.g. 1 October, paid on the 10th) both rules agree. The pay-day rule needs the item's
  schedule, which a salary always has (`R-SAL-1`). Owner picks one; the rest of this spec says "the month's
  threshold" and does not depend on the choice.
- `R-SAL-4` **Reading it back.** One pure function `SalaryMonth.make(salary, month, converter, …)` in
  `AbacusDomain/Calc/` returns for a salary and month: pay, the month's threshold (or nil), excess, shortfall,
  and the conversion note (§2.2). Everything below (chart, tooltips, accessibility text) reads it, so the
  chart and the history can never disagree.

### 2.2 Currency — `R-SAL-5`

There are **two existing per-month conversion rules, and they disagree** (flag):

| Where | Rule | Source |
|---|---|---|
| Income vs expenses, donuts, event totals | each transaction at **its own day's rate** | `R-FX-3`, `Calc.convertedEntries` |
| Monthly budget (headline and limits) | **one rate per month**: the latest rate for the current month, the month's last day for a closed month | D30, `DashboardContent.swift` budget status |
| Net worth | balances at the month's last day; the last point at the latest rate | `R-HOME-1` |

A threshold has no transaction and no day of its own, so "convert at its day's rate" is undefined for it, and
converting pay at the transaction's day but the threshold at some other day would turn **exchange-rate drift into
a fake excess or shortfall**.

- `R-SAL-5` **Proposed rule (Decision D2): the budget rule (D30), applied to both sides.** For a month, pay and
  threshold are each converted to the display currency at **one rate per currency pair for that month**: the
  rate of the month's last day for a closed month, the latest rate for the current month (`rate(from:to:on:)`
  / `latestRate`). When the pay and the threshold share a currency, excess and shortfall are computed in that
  currency first and converted with the same rate, so the comparison is exact and independent of FX. When they
  differ (threshold in USD, pay in PLN) the comparison is inherently exposed to the rate; both are converted at
  the month's rate and the tooltip says so ("compared at the 31 Oct rate, 1 USD = 4.05 PLN"). Excess and shortfall
  are derived from the **converted** pay and threshold, so segments add up to the bar.
  - Not chosen: per-transaction-day rates (the Income vs expenses rule) for pay. It would keep the salary
    bar equal to the same pay in the Income vs expenses widget, but breaks the pay vs threshold comparison
    (the threshold has no day). **Consequence to accept:** a salary's bar can differ slightly from the same salary's
    contribution in "Income vs expenses" (per-day rates) and in "Monthly income". The widget footer states
    "Converted at the rate of <day> (month-end)", next to the existing "NBU rates as of <day>" (`R-FX-4`).
  - A missing rate leaves that salary-month out of the chart and names the pair, as everywhere (D27,
    `DashboardMissingRates`); a raise history row shows its own amounts in their own currencies and needs no rate.
- The display-currency switch (`R-HOME-4`) recomputes the widget like the others; history views show amounts in
  the thresholds' own currencies.

### 2.3 Dashboard widget "Salary vs expectation" — `R-SAL-6…10`

- `R-SAL-6` **Widget.** New `DashboardWidget.salary` ("Salary vs expectation"), **full width**, in the default
  order after "Income vs expenses"; shown only when at least one salary exists (like Debts). Twelve months ending
  at the selected month (`R-HOME-5`), one bar group per month, display currency (`R-HOME-4`), reorderable like
  the other widgets (raw value `salary`; the layout reader already appends new widgets).
- `R-SAL-7` **"All" view.** One **stacked bar per month**, one colour per salary. A salary's segment is
  `[0, max(pay, threshold)]`:
  - the part up to `min(pay, threshold)` is **solid** in the salary's colour;
  - **excess** (pay above the threshold) is drawn on top, **hatched** (diagonal stripes) in the same colour;
  - **shortfall** (pay below the threshold) is the **gap between pay and threshold**, drawn as an **outlined,
    unfilled, dashed** block in the salary's colour with a small "▼" mark, so the bar still reaches the expected
    height and the missing part is visibly empty; excess and shortfall never appear on the same salary-month;
  - a thin tick across the segment marks the threshold level in both cases (it is the boundary hatching
    starts at, or the top of the empty gap);
  - each salary is compared with **its own** threshold; salaries do not net against each other;
  - a salary-month **without a threshold** (before its first one) is drawn solid, no tick, no gap ("no
    threshold" in the tooltip); a month **before the salary's first payment or threshold** has no segment;
  - a month with **no payment** for a salary whose threshold applies is a full shortfall (nothing solid, the
    whole threshold as the empty gap), except the **current month** while the occurrence is still expected and
    not overdue (before its expected day plus the grace days, `scheduledGraceDays`): drawn as an outlined
    block labelled "not paid yet", no shortfall counted (**Decision D3**, default as stated).
  - The shortfall must not rely on colour or hatching alone: the tooltip, the accessibility label and the
    monthly caption carry text ("Net salary: 3,800 paid, 4,000 expected, 200 (5 %) short"); hatched excess says
    "+400 (10 %) above".
  - Tooltip per bar (hover or click, like the Income vs expenses card): per salary pay, threshold, excess or
    shortfall with percent of the threshold, and the month's totals in the display currency. The widget's
    accessibility label summarises the selected month (pattern: `DashboardIncomeExpenses.chartLabel`).
- `R-SAL-8` **Salary filter.** A segmented control (menu when it does not fit) "All · <name> · <name>…" is
  shown **only when two or more salaries have a bar in the 12-month window**; with one salary no filter is
  shown at all and the widget behaves as the single-salary view below. The choice is remembered per session
  (not a setting).
- `R-SAL-9` **Single-salary view** (filter set, or only one salary): one bar per month (same solid / hatched /
  outlined-gap rules), a **threshold line** drawn as a step line through the months' thresholds (it steps in the
  month the threshold rule `R-SAL-3` first applies the new amount), and a **raise marker** (a small symbol on
  the line, tooltip "Raise +10 %: 4,000 → 4,400 from 20 Oct") at the month containing each threshold start day in
  the window. Under the pay-day rule the marker may sit one month before the line steps (raise on the 20th, pay on
  the 10th); the tooltip says "applies from the November payment".
- `R-SAL-10` **Empty and edge states:** no salary → no widget; salary without payments or thresholds → the
  widget invites "Set a threshold" / explains that pay appears after the first payment is matched or linked; the
  salary's settings (thresholds, raise history, colour) open from the widget header.

### 2.4 Raise history — `R-SAL-11…13`

- `R-SAL-11` **Per salary, newest first** (a sheet from the widget header; also reachable from the salary's
  item editor once N5b exists, **Q7**). Row per threshold change after the first: **date** (the start day),
  **previous** and **new** amount (each in its own currency), **raise** (new − previous) and **raise percent** =
  raise / previous threshold. Example: 4,000 → 4,400 is **+400, +10 %**. Percent shows one decimal only when needed
  (+10 %, +9.1 %), computed in `Decimal`. A decrease is shown as a negative change (−300, −7.5 %) and labelled
  "change", not "raise". The first threshold is the last row, "Initial threshold", without raise or percent. Rows can
  be edited and deleted (`R-SAL-2`); a future-dated row is marked "scheduled".
  - **Currency change between thresholds** (e.g. 4,000 USD → 3,800 EUR): both amounts are shown, raise and
    percent are "n/a (currency changed)" — the app does not pick a rate to judge a raise (**Q6**).
- `R-SAL-12` **Last raise.** Header line "Last raise: <date>, N months ago" — the newest threshold with a positive
  change whose start day is not in the future; N = whole elapsed months between that day and today (`Day`
  arithmetic, no time zones); "less than a month ago" under 1; "No raise yet" when there is none. A decrease
  does not reset it. **No eligibility rule and no "you may ask for a raise" hint** is shown (owner: do not
  invent); the line only gives the number to judge by.
- `R-SAL-13` Raise percent over time (e.g. cumulative since the first threshold) is **not** shown in v1.

## 3. Behaviours and edge cases

| Case | Behaviour |
|---|---|
| Raise starts mid-month | `R-SAL-3` / D1 |
| Salary and bonus in one transfer | Matches the occurrence only if within tolerance; otherwise link it by hand ("Link existing…", or "Count as pay of <salary>") |
| Bonus in another account or category | "Count as pay of <salary>" links it (any income transaction); it counts in the month of its own day |
| Income reversal / refund on a linked income | Reduces that month's pay (same sign handling as the report entries, `Calc.reportEntries`) |
| Transaction linked as an occurrence **and** as extra | Blocked: one transaction belongs to one salary once |
| Linked transaction deleted | Link rows are removed with it (repository, no UNIQUE/FK reliance); occurrence returns to expected (N5) |
| Salary item paused/ended | Past bars stay; no new shortfall months after the end month (the month of `endDay` / last payment) |
| New job = new salary | New item and new salary; the old one ends; the filter then shows both while both are in the window |
| Pay day moves | Pay-day rule uses the linked payment's day, so an early/late payment stays in its own month's threshold |
| Payment lands in the next month (31 Oct pay arrives 1 Nov) | Counted in November by the transaction's day (`occurredAt`, not `bookedDay`); the owner sees October short — known limitation, same as every monthly total in the app |
| Display currency has no rate | Salary-month left out and named (D27) |
| Threshold in a currency the app lacks | Not possible: four currencies (D24) |
| Large months (36+ months of history) | Pure function per salary and month; 12 salaries × 12 months in a few ms |

## 4. Schema — migration **v20** (proposed name "v20: salaries")

Additive only: **three new tables, no change to existing tables**, so nothing in `txns`, `scheduledItems`,
snapshots or N5's owned files changes. Style of v18 (STRICT, single `TEXT PRIMARY KEY`, no UNIQUE, plain ids
where a foreign key must not be relied on, `IF NOT EXISTS`, safe to re-run; "one salary per item" and "one
threshold per start day" are guarded in the repository).

```sql
CREATE TABLE IF NOT EXISTS "salaries" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "itemID" TEXT NOT NULL,            -- scheduledItems.id, plain id (item deleted -> repository deletes the salary)
  "colorHex" TEXT NOT NULL,          -- #RRGGBB, distinct per salary
  "createdAt" TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS "salaryThresholds" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "salaryID" TEXT NOT NULL REFERENCES "salaries"("id") ON DELETE CASCADE,
  "amountMinor" INTEGER NOT NULL,    -- > 0, in `currency`
  "currency" TEXT NOT NULL,          -- Currency.rawValue
  "startDay" TEXT NOT NULL,          -- YYYY-MM-DD; no end day stored (R-SAL-2)
  "createdAt" TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS "salaryExtraLinks" (
  "id" TEXT PRIMARY KEY NOT NULL,
  "salaryID" TEXT NOT NULL REFERENCES "salaries"("id") ON DELETE CASCADE,
  "txnID" TEXT NOT NULL REFERENCES "txns"("id") ON DELETE CASCADE,
  "createdAt" TEXT NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS "idx_salaries_itemID" ON "salaries"("itemID");
CREATE INDEX IF NOT EXISTS "idx_salaryThresholds_salaryID" ON "salaryThresholds"("salaryID");
CREATE INDEX IF NOT EXISTS "idx_salaryExtraLinks_salaryID" ON "salaryExtraLinks"("salaryID");
CREATE INDEX IF NOT EXISTS "idx_salaryExtraLinks_txnID" ON "salaryExtraLinks"("txnID");
```

- **Backfill: none.** Existing databases get empty tables; no salary exists until the owner marks one. Nothing
  in v18/v19 data changes. A pre-migration snapshot is taken automatically (N1), as for v19.
- **Alternative considered and not proposed:** columns on `scheduledItems` (`isSalary`, `colorHex`) and on
  `txns` (`salaryItemID`). Fewer tables, but `ALTER`s on the two busiest tables, on the N5-owned entity and on
  the `Txn` Codable snapshot used by `importTxnSnapshots` (needs `decodeIfPresent`, see v19).
- Domain: entities `Salary`, `SalaryThreshold`, `SalaryExtraLink` (`AbacusDomain/Model/Salary.swift`);
  `SalaryThresholds` pure helpers for the effective threshold, raise events and the last raise;
  `SalaryMonth` (`R-SAL-4`).

## 5. Files and tables it will touch

New (this item's own files, a lane can own them outright):

- `AbacusKit/Sources/AbacusDomain/Model/Salary.swift` — entities.
- `AbacusKit/Sources/AbacusDomain/Calc/Salary.swift` — thresholds timeline, raise events, last raise,
  `SalaryMonth`, conversion per `R-SAL-5` (uses `CurrencyConverter`, `Day`, `Month`, `Money`).
- `AbacusKit/Sources/AbacusDomain/Protocols/SalaryRepository.swift` — read/write contract.
- `AbacusKit/Sources/AbacusStore/Repositories/SalaryRepository.swift` — CRUD, append-only threshold rule, one
  salary per item, one salary per transaction (occurrence link vs extra link), cleanup when an item or a
  transaction is deleted.
- `AbacusKit/Sources/AbacusFeatures/Dashboard/DashboardSalary.swift` — widget model (bars, segments, step
  line, raise markers, texts, `missing`).
- `AbacusKit/Sources/AbacusFeatures/Salary/` — raise-history model, threshold editor model.
- `App/macOS/Dashboard/DashboardSalaryCard.swift`, `App/macOS/Salary/SalaryHistorySheet.swift`,
  `SalaryThresholdSheet.swift` — views. Swift Charts has no pattern fill: the hatch is an `ImagePaint` tile or a
  `Canvas` overlay (spike in the lane's first hour; the outlined dashed gap is a plain `strokeBorder`).
- Tests (Swift Testing, synthetic): `AbacusDomainTests/SalaryTests` (timeline, raise %, last raise, month
  rule D1, conversion `R-SAL-5`), `AbacusStoreTests/SalaryRepositoryTests`, `AbacusStoreTests/SalaryV20Tests`,
  `AbacusFeaturesTests/DashboardSalaryTests`.

Shared files (orchestrator-owned, `docs/PLAN.md` §1 — one line each):

- `AbacusStore/Migrations/Schema.swift` — register v20.
- `AbacusFeatures/Dashboard/DashboardLayout.swift` (`DashboardWidget.salary`, default order, full width,
  title), `DashboardModel.swift` (load salaries, recompute, `missingRates` merge), `DashboardDependencies.swift`
  (a `salaries` reader), `App/macOS/Dashboard/DashboardView.swift` / `DashboardWidgetGrid.swift` (register).
- `AbacusStore/Repositories/Backup.swift` and `AbacusStoreTests/BackupTests.swift` — the new tables join the
  backup/seed and the table count (N5 had to do the same).
- `AbacusMCP` — read tool for salaries/raise history: **not in this item** (later, with N2 read tools).
- Scheduled-item editor (N5b, not built) and `AbacusStore/Repositories/ScheduledItemRepository.swift` (N5
  step 1): the "Salary" toggle and the "item deleted → salary deleted" hook. Until N5b exists, "mark as salary"
  is offered from the widget's empty state and from the transaction context menu.
- Docs: `docs/REQUIREMENTS.md` (§4.10 `R-SAL`, change log), `docs/ROADMAP.md` (N10 row), `docs/STATUS.md`,
  `docs/DECISIONS.md` (D1–D3, Q-answers), `CHANGELOG.md`, README screenshot/feature line if the owner wants.

Existing tables only read: `scheduledItems`, `scheduledOccurrences`, `txns`, `accounts`, `categories`,
`fxRates` / overrides (through `CurrencyConverter`), `appSettings` (`displayCurrency`, `scheduledGraceDays`).

## 6. Work split (when approved)

1. N5 steps 1–3 merged (repository, matching, sweep) — prerequisite, not this item.
2. Core: v20 + entities + repository + pure calc + tests (lane `wp/N10a-salary-core`).
3. UI: widget, hatch/gap spike, threshold and history sheets (lane `wp/N10b-salary-ui`, after 2 and an
   approved prototype `docs/design/N10-salary.dc.html` — the owner reviews the visual of the shortfall first).

Effort estimate: M (core S, UI M).

## 7. Open questions and decisions for the owner

| # | Question | Proposed default |
|---|---|---|
| D1 | Which threshold applies to a month when it changes mid-month? | **Pay-day rule** (`R-SAL-3`); owner's "last day of the month" is the alternative and a one-line change |
| D2 | Which rate converts pay and threshold? The app has two per-month rules (per-day for income, one rate per month for the budget) | **One rate per month, the budget rule D30**, both sides (`R-SAL-5`); bar can differ slightly from "Income vs expenses" |
| D3 | Current month, pay not yet due: show a shortfall? | No: "not paid yet" outline until the expected day plus grace days |
| Q1 | Must a salary's category be the one named "Salary"? | Any income category; "Salary" suggested |
| Q2 | Weekly or bi-weekly pay? | Not in v1: monthly schedule only |
| Q3 | Colour per salary: pick manually? | Auto-distinct from `ColorPalette`, editable in the salary's settings |
| Q4 | Raise percent display: one decimal when needed | +10 %, +9.1 % |
| Q5 | New threshold also updates the item's scheduled (forecast) amount? | Offer a checkbox, never silent |
| Q6 | Threshold currency changes (USD → EUR): raise and percent? | "n/a (currency changed)", no rate chosen; a new salary item is the alternative when pay currency changes |
| Q7 | Where does the raise history live without an Upcoming screen? | Sheet from the widget header; item editor link after N5b |
| Q8 | Filter counts salaries with a bar in the window, or all salaries? | In the window |
| Q9 | Does the lane include N5 steps 1–3 if they are still unmerged? | No: prerequisite, separate lanes |
| Q10 | Deleting a salary's item deletes its threshold history? | Yes after a confirmation naming what is lost; alternative: keep a name snapshot and the history |
| Q11 | "Last raise" ignores decreases and future-dated rows | As stated in `R-SAL-12` |
| Q12 | Should the chart count a salary paid in the next month's first days (31 Oct pay arriving 1 Nov) in October? | No: transaction day, as everywhere |

Could not be settled from the code alone: D1–D3 (owner preference), Q5 (how the owner uses the item's amount in
forecasts), Q2/Q6 (how the owner is actually paid), and whether the N5 occurrence/matching behaviour will
include a salary-friendly tolerance (the bonus gap in §1 depends on it).
