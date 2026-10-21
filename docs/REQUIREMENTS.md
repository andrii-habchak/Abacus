# Abacus — tech assignment (TA)

_Status: **DRAFT v0.2** (2026-10-21) — open questions in §9 must be closed before the plan is final._

Requirement IDs (`R-…`) are stable: plans, commits and tests refer to them.

## 1. Goal and scope

A personal, single-user finance tracker for the owner's income and expenses across
UAH, PLN, EUR and USD accounts.

- **Platforms:** macOS app first (v1). iOS app second (v2), sharing the same core code.
- **Data:** stored locally on the device. No server, no telemetry, no bank connections.
- **Out of scope for v1:** bank sync, investments/stock prices, shared/family budgets,
  receipts/attachments, multi-user.

## 2. Tech stack (decided by the implementer, see `DECISIONS.md`)

| Area | Choice |
|------|--------|
| Language / UI | Swift 6, SwiftUI; macOS 26 target (iOS 26 later) |
| Project | xcodegen `project.yml` (as in Vigil); app targets are thin |
| Core code | Local Swift package **`AbacusKit`**: domain model, money/FX math, persistence, CSV import, view-models. Shared by the macOS and iOS apps; testable with `swift test` without launching an app |
| Persistence | SQLite via **GRDB + SQLiteData** (Point-Free): real SQL for SUM/GROUP BY reports, UNIQUE constraints (import dedupe), explicit migrations, in-memory DB in tests, CloudKit sync path for v2. Behind a repository layer. Schema kept CloudKit-safe: UUID keys, archive flags, no reliance on cascades for correctness |
| FX rates | Frankfurter v2 with `providers=NBU` (keyless, covers all 4); fallback: NBU API direct |
| Tests | Swift Testing; pure logic covered first (money, FX, balances, filters, import) |
| Signing | Ad-hoc, run locally (as Vigil) unless iCloud sync is wanted (§9 Q1) |

## 3. Domain model

### 3.1 Money and currency — `R-CUR`
- `R-CUR-1` Currencies: **UAH, PLN, EUR, USD** (closed enum; adding one later is a code change).
- `R-CUR-2` Amounts are stored exactly (integer minor units, 2 decimals for all four),
  never as floating point. Rounding is banker's rounding at conversion time only.
- `R-CUR-3` Every amount keeps its **original currency**; conversion happens only for display
  and aggregates.

### 3.2 Accounts — `R-ACC`
- `R-ACC-1` CRUD accounts: name, currency (fixed after the first transaction), type
  (cash, bank account, card, savings, other), opening balance, icon/colour, sort order.
- `R-ACC-2` Archive instead of delete when an account has transactions; archived accounts are
  hidden from pickers but keep their history and still count in net worth if non-zero
  (_confirm, §9_).
- `R-ACC-3` Balance = opening balance + sum of the account's transaction legs.
- `R-ACC-4` Optional account group (e.g. "Monobank", "Cash") — maps to Saldo's "Parent account".

### 3.3 Categories — `R-CAT`
- `R-CAT-1` Two kinds: **income** and **expense**. Each category has a name, icon, colour,
  sort order.
- `R-CAT-2` CRUD. Deleting a category that is in use asks to reassign its transactions to
  another category of the same kind (or archive it instead).
- `R-CAT-3` A seeded default set on first launch (editable).
- `R-CAT-4` Subcategories: _open question §9_.

### 3.4 Transactions — `R-TX`
- `R-TX-1` Types: **Expense**, **Income**, **Transfer**.
- `R-TX-2` Expense/Income: date, account, amount, category (of matching kind), note (optional).
- `R-TX-3` Transfer: date, from-account, to-account, amount sent, amount received.
  When the two accounts' currencies differ, both amounts are entered (the implied rate is
  shown); same currency → one amount. A transfer has no category and does not count as
  income or expense.
- `R-TX-4` **Attached record** ("fee"): any transaction may carry an attached child record
  with its own category, amount and note, e.g. a bank fee on a transfer or a commission on
  an expense. The child is an expense by default, charged to the parent's (source) account,
  dated with the parent, shown nested under the parent in lists, counted in expense totals
  under its own category, and deleted with the parent.
- `R-TX-5` Note: optional free text on every transaction and attached record.
- `R-TX-6` Edit, delete (with confirmation), duplicate.
- `R-TX-7` Imported transactions remember their source id (Saldo "Transaction ID") so a
  re-import does not create duplicates.

### 3.5 Budget — `R-BUD`
- `R-BUD-1` A monthly budget: a limit in a chosen currency; spent = this month's expenses
  converted to that currency. Shape (single overall limit vs per-category limits, rollover):
  _open question §9_.

### 3.6 Exchange rates — `R-FX`
- `R-FX-1` Daily official NBU rates for the 4 currencies, fetched from
  `https://api.frankfurter.dev/v2/rates?base=…&quotes=…&date=…&providers=NBU`
  (history from 1999; `providers=NBU` is required — without it rates are blended), fallback
  `bank.gov.ua/NBUStatService/v1/statdirectory/exchange?date=YYYYMMDD&json`. Cached locally
  as `(date, base, quote, rate, provider)`, fetched lazily for the dates in use, usable offline.
  Weekend/holiday → most recent earlier rate.
- `R-FX-4` Manual rate override for a date (rarely needed; for corrections).
- `R-FX-2` Aggregates over a period (monthly expenses, budget) convert each transaction at the
  rate **of its date**; net worth converts balances at the **latest** rate.
- `R-FX-3` Manual refresh and "rates as of <date>" shown wherever a converted figure appears.

## 4. Screens and features

### 4.1 Home dashboard — `R-HOME`
- `R-HOME-1` **Net worth** widget: total of all account balances in the display currency,
  with per-account breakdown on expand.
- `R-HOME-2` **Monthly budget** widget: limit, spent, remaining, % used, days left in month.
- `R-HOME-3` **Monthly expenses** donut: current month's expenses by category (attached fee
  records included under their own category); legend with amounts and %; click a slice →
  transaction list filtered to that category and month.
- `R-HOME-4` **Display currency** switch (UAH / PLN / EUR / USD) for all widgets; the choice
  is remembered.
- `R-HOME-5` Month selector for widgets 2–3 (_confirm, §9_).

### 4.2 Transaction list — `R-LIST`
- `R-LIST-1` Default range: last month (_definition to confirm, §9_), newest first.
- `R-LIST-2` Filters, combinable:
  1. Category (multi-select)
  2. Date range (from–to, with presets: this month, last month, last 3 months, this year)
  3. Account (multi-select)
  4. Type: Income / Expense (_and Transfer? §9_)
- `R-LIST-3` Sort by date: ascending / descending (default descending).
- `R-LIST-4` Rows grouped by day; each row: category icon, category/description, account,
  note preview, amount in original currency (coloured by type). Attached records shown
  nested under their parent.
- `R-LIST-5` Footer totals for the filtered set (income, expense, net) in the display currency.
- `R-LIST-6` Text search over notes and descriptions (combines with the filters).

### 4.3 Transaction editor — `R-EDIT`
- `R-EDIT-1` One form for all three types, switching fields by type; keyboard-first on macOS
  (⌘N new, ⏎ save, ⎋ cancel).
- `R-EDIT-2` "Add fee" adds the attached record (category, amount, note).

### 4.4 Accounts and categories management — `R-MGMT`
- `R-MGMT-1` Accounts screen: list with balances (original currency), CRUD, archive.
- `R-MGMT-2` Categories screen: income / expense tabs, CRUD, reorder, reassign-on-delete.

### 4.5 CSV import from Saldo — `R-IMP`
Source columns: Transaction ID, Transaction Date, Description, Parent account, Account,
Account, Type, Archived, Journal Type, Amount, Currency, Tags, Accrual Month, Notes.
- `R-IMP-1` Pick a `.csv` file → parse → **preview** (rows, detected accounts, categories,
  currencies, date range, problems) before anything is written.
- `R-IMP-2` Map Saldo accounts/categories to existing ones or create them; the mapping is
  remembered for the next import.
- `R-IMP-3` Transfers and fees are reconstructed according to the Saldo format rules
  (_need a sample file, §9_).
- `R-IMP-4` Idempotent: rows whose Transaction ID was already imported are skipped.
- `R-IMP-5` Import runs in one database transaction: all or nothing; a summary is shown after.

### 4.6 Settings — `R-SET`
- `R-SET-1` Default display currency, rate refresh, data folder location.
- `R-SET-2` Backup: export all data to a file and restore from it (_v1 or later? §9_).

## 5. Non-functional
- `R-NF-1` Offline-first; only the FX fetch uses the network.
- `R-NF-2` Smooth with 20 000 transactions (list scroll, filter < 200 ms).
- `R-NF-3` Native macOS look: sidebar navigation, toolbar, light/dark mode, standard controls.
- `R-NF-4` UI language English (_Ukrainian later? §9_); number/date formatting from system locale.
- `R-NF-5` Core logic covered by unit tests; every requirement ID with logic has at least one test.

## 6. How screens are agreed (design process)

1. **Wireframes as interactive HTML prototypes** styled like macOS (sidebar, toolbar, list,
   inspector) — one private shareable web page per screen group, clickable, with fake
   data. You review in the browser and leave comments per screen; we iterate until you approve.
2. Approved screens are frozen into `docs/design/` (screenshot + short spec of each screen's
   states) so any agent builds against the same picture.
3. **SwiftUI check:** the first build phase renders the real views with mock data; you get
   screenshots of the actual app for a final look before the views are wired to data.

## 7. Milestones (summary — details in `PLAN.md`)
- v1 macOS: everything in §3–§5.
- v2 iOS: same core package, iPhone UI, (optional) iCloud sync.

### Backlog (v2+, not in v1 unless pulled in by §9)
Subcategories · per-category budgets with rollover · recurring/scheduled transactions ·
tags · payee with autocomplete · split transactions (the attached-record model generalises
to this, so the schema keeps a parent→children relation) · reconciliation ("cleared" flag,
balance adjustment) · CSV export · net-worth history chart · iCloud sync.

Deliberately skipped: bank sync, shared wallets, envelope/zero-based budgeting, investments,
debts/loans module, AI categorisation.

## 8. Glossary
- **Leg** — one account-side effect of a transaction (a transfer has two legs).
- **Attached record** — child record (usually a fee) belonging to a parent transaction.
- **Display currency** — the currency aggregates are shown in.

## 9. Open questions

Each has a proposed default. Answer "default" or override; the answer then replaces the
_open question_ markers above and lands in `DECISIONS.md`.

| # | Question | Proposed default |
|---|----------|------------------|
| Q1 | iCloud sync Mac ↔ iPhone in v2? (needs the paid Apple Developer Program; v1 is unaffected because the schema is sync-safe either way) | Decide at v2; v1 local only |
| Q2 | Saldo CSV: provide an anonymised sample containing an expense, an income, a same-currency transfer, a cross-currency transfer, a transaction with a fee, and an archived account. (No public docs for this format exist.) | **Blocking for `R-IMP-3`** |
| Q3 | "Last month" in the list default = current calendar month, previous calendar month, or last 30 days? | Last 30 days |
| Q4 | Type filter: Income / Expense only, or also Transfer? | Income, Expense, Transfer |
| Q5 | Budget shape: one overall monthly limit, or per-category limits? Rollover? | One overall limit, no rollover in v1 |
| Q6 | Subcategories (one level) in v1? | No (backlog) |
| Q7 | Attached record: exactly one per transaction, or several? Can it be income (e.g. cashback)? | Several allowed, UI optimised for one; expense or income |
| Q8 | Month selector on the budget and donut widgets, or current month only? | Month selector (← →) |
| Q9 | Backup export/restore in v1? | Yes — a single-file export/restore |
| Q10 | UI language: English only, or Ukrainian too? | English only in v1, strings localisable |
| Q11 | Saldo "Tags": import and keep them (needs a tags field), or drop? | Keep as plain text on the transaction; tag features in backlog |
| Q12 | Archived accounts with a non-zero balance: count in net worth? | Yes |
| Q13 | Date only, or date + time on transactions? | Date + time, list shows date |
