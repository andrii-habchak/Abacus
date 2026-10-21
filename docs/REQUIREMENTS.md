# Abacus — tech assignment (TA)

_Status: **v1.3 — agreed** (2026-10-21). All open questions closed (§9). Changes after this point
are recorded in §10._

Requirement IDs (`R-…`) are stable: plans, commits and tests refer to them.

## 1. Goal and scope

A personal, single-user finance tracker for the owner's money across UAH, PLN, EUR and USD
accounts, with as little manual entry as possible (bank and Saldo imports).

- **Platforms:** macOS app first (v1). iOS app second (v2), sharing the same core code;
  iCloud sync between them in v2 (needs the paid Apple Developer Program then, not before).
- **Data:** stored locally. Network is used only for exchange rates. No bank connections,
  no telemetry.
- **Out of scope for v1:** iOS, sync, investments/stock prices, shared budgets,
  receipts/attachments, multi-user, recurring transactions.

## 2. Tech stack (see `DECISIONS.md` D5–D8)

| Area | Choice |
|------|--------|
| Language / UI | Swift 6, SwiftUI; macOS 26 target (iOS 26 later) |
| Project | xcodegen `project.yml` (as in Vigil); app targets are thin |
| Core code | Local Swift package **`AbacusKit`**: domain, money/FX math, persistence, importers, view-models. Shared by the macOS and iOS apps; tested with `swift test` without launching an app |
| Persistence | SQLite via **GRDB + SQLiteData**, behind a repository layer. Schema kept CloudKit-safe: UUID keys, archive flags, no reliance on cascades for correctness |
| FX rates | Official NBU rates via Frankfurter v2 (`providers=NBU`); fallback NBU API |
| Tests | Swift Testing. Importers tested on synthetic fixtures committed under `AbacusKit/Tests/Fixtures/`; real exports stay in git-ignored `samples/private/` |
| Signing | Ad-hoc, run locally (as Vigil) for v1 |

## 3. Domain model

### 3.1 Money and currency — `R-CUR`
- `R-CUR-1` Account and display currencies: **UAH, PLN, EUR, USD**.
- `R-CUR-2` Amounts stored exactly as integer minor units + currency code; `Decimal` for math,
  never floating point. Rounding (banker's) only when converting.
- `R-CUR-3` Every amount keeps its original currency; conversion only for display and aggregates.
- `R-CUR-4` **Transaction currency**: an expense/income is entered in any currency (the four
  plus other ISO 4217 codes, e.g. HUF, CHF). When it differs from the account currency, the
  amount charged to the account is also recorded (pre-filled at the day's rate, editable).
  Balances and reports use the charged amount; the entered amount is kept as the original
  amount (`originalAmountMinor` / `originalCurrencyCode`).

### 3.2 Accounts — `R-ACC`
- `R-ACC-1` CRUD accounts: name, currency (fixed after the first transaction), kind, opening
  balance + opening date, optional bank account number (IBAN, used by importers to recognise
  own-account transfers), icon/colour, sort order, optional group (e.g. "Monobank", "PKO").
- `R-ACC-2` Kinds. **Assets:** cash, bank account, card, savings/deposit, investment.
  **Liabilities:** credit card, loan, debt (money owed to/by a person).
- `R-ACC-3` Balance = opening balance + sum of the account's transaction effects.
- `R-ACC-4` **Archive**: archived accounts are hidden from pickers and dashboards and are
  **excluded from net worth**; history stays. Archiving an account whose balance is not zero
  shows a warning ("Balance is X. Archive anyway?") and needs confirmation. Unarchive is possible.
- `R-ACC-5` Delete only when the account has no transactions; otherwise archive.

### 3.3 Categories — `R-CAT`
- `R-CAT-1` Two kinds: **income** and **expense**; name, icon, colour, sort order.
- `R-CAT-2` **Subcategories, one level** (e.g. Food → Groceries, Eating out). A transaction may use
  a parent or a child. Parent totals include their children.
- `R-CAT-3` CRUD. Deleting a category in use asks to reassign its transactions (and budget) to
  another category of the same kind, or to archive it instead. Deleting a parent asks what to do
  with its children (move up or reassign).
- `R-CAT-4` A seeded default set on first launch (editable).

### 3.4 Transactions — `R-TX`
- `R-TX-1` Types: **Expense**, **Income**, **Transfer**.
- `R-TX-2` Common fields: date **and time**, account, amount, description (merchant/payee, from
  imports or typed), note (optional), optional event (§3.6), source (manual / Saldo / PKO),
  import fingerprints, and a *pending at the bank* flag (`R-IMP-PKO-2`).
- `R-TX-3` Expense/Income: category of the matching kind; optional original amount (`R-CUR-4`).
- `R-TX-4` **Refund**: an expense may be marked as a refund (money comes back into the account;
  it keeps its expense category); income may likewise be reversed. Shown with its own marker.
  How refunds are counted is a setting (`R-SET-3`): **off by default** → a refund is reported as
  income ("Refunds") and the category's spending is unchanged; on → it is subtracted from the
  category's spending and budget. Balances are the same either way.
- `R-TX-5` Transfer: from-account, to-account, amount sent, amount received. Different
  currencies → both amounts entered, implied rate shown; same currency → one amount. No category;
  not counted as income or expense. Transfers to/from liability accounts are lending/borrowing
  and repayments.
- `R-TX-6` **Attached records**: any transaction may carry **zero or more** attached records,
  each with its own category, amount, kind (expense or income — e.g. a fee or cashback) and note.
  They hit the parent's (source) account, share its date, are shown nested under the parent,
  count in totals under their own category, and are deleted with the parent. The account effect
  of a transaction = main amount ± attached records. The same model covers splits (one card
  payment across several categories).
- `R-TX-7` Edit, delete (with confirmation), duplicate.

### 3.5 Budget — `R-BUD`
- `R-BUD-1` A **monthly budget**: a total monthly limit in a chosen currency, **allocated across
  categories** (e.g. Rent 4 000, Groceries 2 500). The part of the total not allocated is shown
  as "unallocated / other".
- `R-BUD-2` Spent per category = that month's expenses (attached expense records included;
  refunds subtracted only when `R-SET-3` is on) converted to the budget currency at each transaction's date rate. A parent
  category's limit covers its subcategories.
- `R-BUD-3` The budget repeats every month until changed; a change applies from the chosen month
  onward (past months keep their limits). No rollover of unspent money in v1.

### 3.6 Events — `R-EVT`
Answers "how do I track a vacation / a relocation / the car" (what Saldo tags were used for).
- `R-EVT-1` An **event** has a name, optional date range, optional budget, and an archived flag.
- `R-EVT-2` A transaction belongs to **at most one** event. While an event's date range is active,
  the editor pre-selects it for new expenses (can be cleared).
- `R-EVT-3` Event view: total spent (display currency), by category, transaction list; the list
  filter can filter by event.
- `R-EVT-4` Events are orthogonal to categories: "Trip 2025" spending still lands in Eating out,
  Transport, etc., so monthly category reports stay correct.

### 3.7 Exchange rates — `R-FX`
- `R-FX-1` **Automatic:** on launch and then daily (and on demand via "Refresh rates") the app
  requests the latest official NBU rates for the 4 currencies from
  `https://api.frankfurter.dev/v2/rates?base=…&quotes=…&date=…&providers=NBU`
  (fallback `bank.gov.ua/NBUStatService/v1/statdirectory/exchange?date=YYYYMMDD&json`).
  Historical rates for dates in use are fetched lazily and cached as
  `(date, base, quote, rate, provider)`. Weekend/holiday → most recent earlier rate. Works
  offline from the cache.
- `R-FX-2` **Manual:** the user can set a rate for a currency pair and date (or "from this date
  on"). A manual rate overrides the fetched one for that date and is marked as manual in the
  rates screen; it can be removed to fall back to the fetched rate.
- `R-FX-3` Period aggregates (monthly expenses, budget, events) convert each transaction at the
  rate of its date; net worth converts balances at the latest rate.
- `R-FX-4` Wherever a converted figure appears, "rates as of <date>" is visible; a fetch failure
  shows a non-blocking warning and the last known rates are used.
- `R-FX-5` Rates screen: current rates table, last update time, manual overrides list.

## 4. Screens and features

### 4.1 Home dashboard — `R-HOME`
- `R-HOME-1` **Net worth**: a **monthly chart** — one point per month (net worth at the month's
  end, converted at that day's rate), the last point is today (latest rate) and is the headline
  figure; change since the previous month-end; hover shows a month's value. Assets − liabilities
  of non-archived accounts in the display currency, with a per-account breakdown on expand.
- `R-HOME-2` **Monthly budget**: total limit, spent, remaining, % used, days left; per-category
  bars; **categories over their limit are highlighted** (and near-limit, ≥ 90 %, shown in amber).
- `R-HOME-3` **Monthly expenses** donut by category (parents, expandable to subcategories);
  legend with amounts and %; click a slice → transaction list filtered to that category and month.
- `R-HOME-4` **Display currency** switch (UAH / PLN / EUR / USD) for all widgets; remembered.
- `R-HOME-5` Month selector (← →) for the budget and donut widgets.

### 4.2 Transaction list — `R-LIST`
- `R-LIST-1` Default range: **last 30 days**, newest first.
- `R-LIST-2` Filters, combinable: category (multi, parent selects children), date range (with
  presets), account (multi), type (Income / Expense / Transfer), event.
- `R-LIST-3` Sort by date ascending / descending (default descending).
- `R-LIST-4` Rows grouped by day: category icon, description, account, note preview, time on
  hover/detail, amount in original currency coloured by type; attached records nested.
- `R-LIST-5` Footer totals for the filtered set (income, expense, net) in the display currency.
- `R-LIST-6` Text search over description and note.

### 4.3 Transaction editor — `R-EDIT`
- `R-EDIT-1` One form for all three types; keyboard-first (⌘N new, ⏎ save, ⎋ cancel).
- `R-EDIT-2` "Add fee / add line" adds attached records.
- `R-EDIT-3` Category is suggested from the description using the categorisation rules (`R-IMP-8`).
- `R-EDIT-4` **Currency picker** next to the amount (expense/income). A new transaction starts
  with the **last used currency and account**. If the currency differs from the account's, a
  "Charged to account" amount is shown (`R-CUR-4`).
- `R-EDIT-5` A new **transfer** starts with the **From and To accounts of the last transfer**.

### 4.4 Management screens — `R-MGMT`
- `R-MGMT-1` Accounts: grouped list with balances, CRUD, archive (`R-ACC-4`).
- `R-MGMT-2` Categories: income / expense tabs, tree with subcategories, CRUD, reorder,
  reassign-on-delete.
- `R-MGMT-3` Budget editor: monthly total + per-category allocations.
- `R-MGMT-4` Events: CRUD, archive.
- `R-MGMT-5` Exchange rates (`R-FX-5`).
- `R-MGMT-6` Categorisation rules: list, edit, delete (`R-IMP-8`).

### 4.5 Import — `R-IMP`
Common pipeline for all sources: **parse → normalise → match/dedupe → preview → commit**.
- `R-IMP-1` Pick a file → the format is detected (Saldo or PKO) → parsed into normalised rows →
  **preview** before anything is written: counts (new / duplicate / possible duplicate / needs
  review / skipped), accounts and categories to create or map, date range, warnings.
- `R-IMP-2` **Mapping**: source accounts and categories are mapped to Abacus ones or created;
  mappings are remembered per source for the next import.
- `R-IMP-3` **Deduplication, exact:** every imported transaction stores a source fingerprint with
  a UNIQUE constraint. Re-importing the same or an overlapping file never creates duplicates.
  - Saldo: `saldo:<Transaction ID>`.
  - PKO (no ids): `pko:<account>:<operation date>:<value date>:<amount>:<balance after>:<hash of
    the description fields>`. The running balance makes the key unique per account even for two
    identical purchases on the same day.
- `R-IMP-4` **Deduplication, fuzzy (cross-source):** a row that has no exact match but looks like
  an existing transaction from another source or manual entry (same account, same amount and
  currency, date ± 3 days, similar description) is flagged **possible duplicate**; the preview
  default is *skip*, the user can switch it to *import* or *link* (link = keep the existing
  transaction and store the new fingerprint on it so it is recognised next time).
- `R-IMP-5` **Needs review** queue in the preview for rows the importer cannot place confidently
  (e.g. an unpaired transfer half); each can be resolved (pair, choose category, skip) before commit.
- `R-IMP-6` Commit runs in one database transaction — all or nothing; a summary is shown and the
  batch is listed in an import history with **"Undo import"** (deletes that batch's transactions).
- `R-IMP-7` Imports never change opening balances or existing transactions, except via *link*.
- `R-IMP-8` **Categorisation rules** ("description contains X → category Y", optionally per
  account) are created from the user's choices in the preview and applied to later imports and
  the editor. This is what removes the manual work for recurring merchants.

#### Saldo CSV — `R-IMP-SALDO` (details: `docs/import/saldo-format.md`)
- `R-IMP-SALDO-1` Double-entry rows grouped by Transaction ID; leg types (BANK_ACCOUNTS, CASH,
  OTHER_ASSETS, LIABILITIES, EXPENSES, INCOME, EQUITY, MONEY_ON_THE_WAY) are converted to Abacus
  accounts, categories and transaction types per the mapping table in the format doc.
- `R-IMP-SALDO-2` Transfers recorded by Saldo as two halves through "Money on the way" are paired
  into one transfer (same in-transit amount and currency, different accounts, ≤ 3 days apart);
  unpaired halves go to *needs review*.
- `R-IMP-SALDO-3` EQUITY "Initial balance" rows become account opening balances (only when the
  account is created by this import).
- `R-IMP-SALDO-4` Saldo tags are not imported as tags; in the preview the user may turn selected
  tags into events (e.g. "Trip 2025").

#### PKO BP CSV — `R-IMP-PKO` (details: `docs/import/pko-format.md`)
- `R-IMP-PKO-1` Windows-1250 encoded, comma-separated, quoted; one file = one PKO account (the file
  does not name it) → the user picks the target account once; remembered.
- `R-IMP-PKO-2` Rows "Blokada" (pending card holds, balance "W rozliczeniu") are **imported as
  completed payments** (expense dated by `Data waluty`), marked *pending at the bank*. When a later
  export contains the settled row of the same purchase (same account, value date ± 3 days, same
  merchant, amount equal or within 5 %), the importer **upgrades** the existing transaction
  instead of adding a new one: the settled amount wins, the date stays the purchase day, the
  booking day is recorded, the settled fingerprint is added, the pending mark is cleared. This is automatic (not a "possible duplicate"), but listed
  in the preview as "settles N pending payments".
- `R-IMP-PKO-4` Every PKO row is dated by its **purchase day** (`Data waluty`); the booking day
  (`Data operacji`, 1–3 days later for card payments) is kept on the transaction for reference
  (`Txn.bookedDay`).
- `R-IMP-PKO-3` Signed amount → expense/income; a counterparty account number that belongs to an
  Abacus account (`R-ACC-1`) → transfer (paired with the other side if already imported);
  "Oryginalna kwota operacji" → original amount (`R-CUR-4`); merchant/recipient + title →
  description.

### 4.6 Settings and backup — `R-SET`
- `R-SET-1` Default display currency, rates refresh, data folder location.
- `R-SET-2` **Backup:** export all data to one file and restore from it (restore replaces all
  data after confirmation).
- `R-SET-3` "Refunds reduce category spending" — off by default (`R-TX-4`).

## 5. Non-functional
- `R-NF-1` Offline-first; only the FX fetch uses the network.
- `R-NF-2` Smooth with 20 000 transactions (list scroll, filter < 200 ms); importing the
  10 000-row Saldo export < 10 s.
- `R-NF-3` Native macOS look: sidebar navigation, toolbar, light/dark mode, standard controls.
- `R-NF-4` UI in English; strings localisable; number/date formatting from system locale.
- `R-NF-5` Every requirement with logic has at least one unit test referencing its ID.
- `R-NF-6` Real exports never leave `samples/private/` (git-ignored); fixtures are synthetic.

## 6. How screens are agreed (design process)

1. **Interactive HTML prototypes** styled like macOS (sidebar, toolbar, list, inspector), one
   private shareable web page per screen group, clickable, with fake data. The owner reviews and
   comments per screen; iterate until approved.
2. Approved screens are frozen into `docs/design/` (screenshot + short spec of each screen's
   states) so every agent builds against the same picture.
3. **SwiftUI check:** the first UI phase renders the real views with mock data; the owner gets
   screenshots of the actual app for a final look before the views are wired to data.

## 7. Milestones
- **v1 macOS:** everything in §3–§5.
- **v2 iOS + iCloud sync:** same core package, iPhone UI, CloudKit sync via SQLiteData.

### Backlog (v2+)
Per-category budget rollover · recurring/scheduled transactions · tags · reconciliation
("cleared" flag, statement balance check) · CSV export · more bank
formats (Monobank, Revolut).

Deliberately skipped: bank sync, shared wallets, envelope/zero-based budgeting, investments,
AI categorisation.

## 8. Glossary
- **Effect** — what a transaction does to one account's balance (a transfer has two).
- **Attached record** — child record (fee, cashback, split line) belonging to a parent transaction.
- **Event** — a named spending context across categories (trip, relocation, car).
- **Fingerprint** — the stable key of an imported row used for deduplication.
- **Display currency** — the currency aggregates are shown in.

## 9. Open questions

### Answered (2026-10-21) — all
| # | Answer |
|---|--------|
| Q1 | iCloud sync: yes, in v2. Nothing in v1 needs the paid membership. |
| Q2 | Saldo sample provided (`samples/private/`, git-ignored); PKO sample provided too. |
| Q3 | Last 30 days. |
| Q4 | Type filter includes Transfer. |
| Q5 | Monthly total allocated across categories; widget flags categories over their limit. |
| Q6 | Subcategories: yes (one level). |
| Q7 | Several attached records; expense or income. |
| Q8 | Month selector: yes. |
| Q9 | Backup export/restore in v1: yes. |
| Q10 | English only in v1. |
| Q11 | Tags: not imported. Short-term events (vacations) → Events, §3.6. |
| Q12 | Archived accounts are excluded from net worth; warn before archiving a non-zero account. |
| Q13 | Date and time. |

| Q14 | Liability (credit card, loan, debt) and investment accounts in v1; net worth = assets − liabilities. |
| Q15 | Refund counting is a setting, off by default (`R-SET-3`). |
| Q16 | Keep the merchant's original amount/currency, informational (`R-CUR-4`). |
| Q17 | Description field besides Note (`R-TX-2`). |
| Q18 | Events replace Saldo tags (§3.6, `R-IMP-SALDO-4`). |
| Q19 | Explicit budget total with an "unallocated" remainder (`R-BUD-1`). |
| Q20 | Manual rates per date and "from a date until changed" (`R-FX-2`). |
| Q21 | Categorisation rules learned from import choices (`R-IMP-8`). |
| — | PKO "Blokada" rows are imported as completed payments and upgraded when they settle (`R-IMP-PKO-2`). |

| Q22 | PKO rows are dated by the purchase day (`Data waluty`); the booking day is kept for reference (`R-IMP-PKO-4`). |

### Open
| # | Question | Proposed default |
|---|----------|------------------|
| Q23 | Saldo: ~85 cross-currency transfers have halves whose in-transit amounts are in different currencies (each in its own account's currency), booked within 2 minutes between different accounts. Pair them automatically in a second pass, or leave them for manual review? | Pair automatically (different accounts, ≤ 2 minutes, one candidate each); anything ambiguous stays in review |

## 10. Change log

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-10-21 | Agreed baseline. |
| 1.1 | 2026-10-21 | `R-HOME-1`: net worth is a monthly chart ending at today (owner's prototype review); removed from backlog. |
| 1.3 | 2026-10-21 | Q22: PKO rows dated by the purchase day, booking day kept (`R-IMP-PKO-2`, new `R-IMP-PKO-4`). |
| 1.2 | 2026-10-21 | Editor review: currency picker replaces "paid in another currency" (`R-CUR-4`, `R-EDIT-4`); last-used currency/account and transfer accounts as defaults (`R-EDIT-4/5`). |
