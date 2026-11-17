# Abacus — tech assignment (TA)

_Status: **v1.13 — agreed** (2026-11-17). All open questions closed (§9). Changes after this point
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
  receipts/attachments, multi-user. (Recurring transactions moved into scope in v1.13, §4.8.)

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
  A refund may be **linked** to the expense it returns (`refundOfID`, v1.11): a linked refund always
  reduces that expense's category spending, on the refund's own day, whatever `R-SET-3` says; several
  refunds per expense up to its amount, also across currencies (converted at the refund's date).
  Import offers a refund link for incoming rows that match an expense.
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
- `R-BUD-1` A **monthly budget**: a **total limit in a chosen currency** plus per-category
  limits, **each in its own currency** (e.g. total 15 000 PLN; Groceries 400 EUR, Home 5 747 PLN).
  "Unallocated" = total − category limits converted at the latest rate. The Budget page and the
  dashboard widget show amounts in the display currency (switcher on both); category statuses are
  decided in each limit's own currency (v1.6, D46).
- `R-BUD-2` Spent per category = that month's expenses (attached expense records included;
  refunds subtracted only when `R-SET-3` is on) converted to that category limit's currency at each transaction's date rate. A parent
  category's limit covers its subcategories.
- `R-BUD-3` The budget repeats every month until changed; a change applies from the chosen month
  onward (past months keep their limits). No rollover of unspent money in v1.

### 3.6 Events — `R-EVT`
Answers "how do I track a vacation / a relocation / the car" (what Saldo tags were used for).
- `R-EVT-1` An **event** has a name, colour, optional date range, optional budget, and an archived flag.
- `R-EVT-2` A transaction belongs to **at most one** event. While an event's date range is active,
  the editor pre-selects it for new expenses (can be cleared).
- `R-EVT-3` Event view: total spent (display currency), by category, transaction list; the list
  filter can filter by event.
- `R-EVT-4` Events are orthogonal to categories: "Trip 2025" spending still lands in Eating out,
  Transport, etc., so monthly category reports stay correct.

### 3.6a Debts — `R-DEBT` (v1.7, D51)
Answers "who owes me, whom do I owe, and how much".
- `R-DEBT-1` A **debt** is a **person** and a **currency**; one person can have debts in several
  currencies, each with its own balance, never netted across currencies. A debt is **not an
  account**. Fields: person name, currency, optional due date, note, **"Count in net worth"**
  checkbox (per debt), settled/archived flag.
- `R-DEBT-2` Balance direction: positive = they owe me, negative = I owe them; shown as "owes you"
  / "you owe".
- `R-DEBT-3` **Records** (each with day, amount in the debt's currency, optional note):
  *I lent* (money from my account to them), *They repaid* (money to my account), *I borrowed*
  (money from them to my account), *I repaid* (money from my account to them), *Paid on their
  behalf* (I paid a bill for them from my account; they owe me), *Forgive* (close part or all of
  the balance, no money moves). A record that moves money names my account; if the account's
  currency differs, the account amount is entered too (like a cross-currency transfer). My
  account balances change accordingly; the record appears in the transaction list on that account
  marked as a debt record.
- `R-DEBT-4` Expense/income flags, **off by default**: *I lent* and *Paid on their behalf* have
  "Count as expense" (then they appear in monthly expenses and the budget under a "Debts"
  category); *They repaid* has "Count as income". *Forgive* of money owed to me has "Count as
  expense" (on by default — a forgiven debt is an expense on the forgiveness day). Unflagged
  records never touch expense/income reports.
- `R-DEBT-5` **Debts tab** (sidebar, Overview): people with their balances per currency and
  direction, search, filter Active/Settled; a person's detail lists the records, totals, due date;
  add record / edit / delete. A debt whose balance reaches zero can be marked settled (moves to
  Settled, drops off the widget).
- `R-DEBT-6` **Dashboard Debts widget**: totals "Owed to you" and "You owe" in the display
  currency, and a per-person list (largest first, per-currency balances).
- `R-DEBT-7` Net worth includes a debt only when its "Count in net worth" is on (owed to me =
  asset, I owe = liability).
- `R-DEBT-8` Migration: existing accounts of kind *debt* become debts (person = account name,
  currency = account currency); their transfers become records with the same days and amounts;
  every own-account balance and the net worth (with "Count in net worth" on) stay exactly equal.
- `R-DEBT-9` (v1.8) **One payment, one transaction.** Every money movement of a debt is exactly
  one transaction, linked to its record; a bank row and a debt record for the same payment must
  never both count. Linking is automatic where possible, manual work is the fallback.
- `R-DEBT-10` (v1.8) **Import**: a row can become a debt record ("Debt…": person, debt, kind
  suggested from the direction — money out → I lent / I repaid, money in → They repaid / I
  borrowed); the imported row becomes the record's transaction.
- `R-DEBT-11` (v1.8) **Transactions**: "Convert to debt record" on an existing transaction; the
  transaction becomes the record's transaction (no second transaction).
- `R-DEBT-12` (v1.8) **Rules**: action "Record as debt for <person>" (kind from the direction),
  applied on import like the other rule actions.
- `R-DEBT-13` (v1.8) **Matching**: a bank row for a payment already recorded by hand as a debt
  record is recognised (shown as Already imported / linked), in both directions (money out and
  money in), and never imported as a second transaction.
- `R-DEBT-14` (v1.8) **Several accounts per person**: a person's records may use any of my
  accounts (Revolut, PKO, Mono, …) in any currency; the person's detail shows the account of each
  record and the debt view includes all of them.
- `R-DEBT-15` (v1.8) **Currency switch on Debts**: per-currency balances stay as they are (never
  netted, `R-DEBT-1`); the Debts tab follows the display-currency switch and also shows each
  person's total converted to the display currency.
  Imports that would create a debt account create/find a debt instead.

**v1.9 — accounts drive debts (D59–D61).** `R-DEBT-16…22` supersede the parts of `R-DEBT-1`, `-3`, `-9`,
`-11` that tie a debt to one currency and that make a payment a record leg. Where they conflict, v1.9 wins.
- `R-DEBT-16` A debt is **one person** (name, optional due date, note, "Count in net worth", settled)
  and has **no currency**; there is no separate Person entity (D60). The name is editable (rename);
  autocomplete over existing names is offered in the import, convert and rule dialogs.
- `R-DEBT-17` A debt has **many linked accounts**; an account belongs to at most one debt. Two kinds,
  both *the person's* accounts, never my own: **external** (the person's real account whose statement
  I import, e.g. Revolut Anna) and **virtual** (a debt-kind account I keep for the person, no statement;
  created from the debt dialog with "Create account"). The new/edit dialog has an account search.
- `R-DEBT-18` **Balance** per currency = signed sum of the transactions on the linked accounts (money
  into the person's account = they owe me more; out = they repaid) + the account's opening balance +
  manual records (forgive, adjustments; each with its own currency). Never netted across currencies;
  the display-currency switch adds a converted total. Importing a statement of a linked account
  updates the debt with no per-row action. Linked accounts' balances are counted in net worth only
  through the debt (flag on), never twice.
- `R-DEBT-19` **Payments from my own accounts** (PKO → Anna) are an ordinary **transfer** between my
  account and the person's virtual account, visible in the Transactions list under both accounts.
  "Convert to debt record" becomes "Transfer to debt account…"; the import row action "Debt…" and the
  rule action "Record as debt for <person>" produce the same transfer; a bank row for a payment already
  entered by hand is matched (same amount, direction, ±3 days) and shown as Already imported.
  Existing C17 records and legs are migrated to such transfers; their fingerprints stay on the
  transaction of my own account, so a repeated import never duplicates them.
- `R-DEBT-20` A hint (not an automatic merge) when two accounts of one debt show the same amount in a
  short window (the same payment on an external and a virtual account).
- `R-DEBT-21` **Debts UI.** Header: "Edit debt" and "Show transactions" (replace "Add currency");
  right-click menu on a debt in the list and on the dashboard widget: Edit, Show transactions, Mark
  settled, Delete; per-account breakdown (account, currency, balance) and an opening balance per
  account; a hint for a linked account with no transactions in the last period. **Sign convention
  (display only):** money they owe me is shown **negative and red** ("you lent"), money I owe
  **positive and green** ("you borrowed"), in the Debts tab, its header and the dashboard widget;
  stored balances keep their sign. "Count in net worth" is **off by default for new debts**.
- `R-DEBT-21a` (v1.10) The dashboard widget header and every debt row show **one total** in the display
  currency (signed and coloured per R-DEBT-21, "No rate" when a balance cannot be converted); per-currency
  amounts are only a small caption for debts with several currencies.
- `R-DEBT-22` **Transactions filter.** The Transactions list has a debt filter; selecting a debt, or
  "Show transactions" on a debt, selects all its linked accounts as removable chips (account filter
  alongside), so any account can be un-/selected.

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
  An edit button opens the Budget screen.
- `R-HOME-3` **Monthly expenses** donut by category (parents, expandable to subcategories);
  legend with amounts and %; click a slice → transaction list filtered to that category and month.
  Only a click navigates; hovering never switches screens (the app never changes section without
  a user action).
- `R-HOME-4` **Display currency** switch (UAH / PLN / EUR / USD) for all widgets; remembered.
  The switch is shown only on screens it affects: Dashboard, Transactions, Accounts, Events,
  Budget; order EUR, USD, PLN, UAH. "New transaction" is not shown on Budget and Rules.
- `R-HOME-6` (v1.6) **Monthly income** donut (like expenses) and an **income vs expenses**
  widget (last 12 months, bars per month with the net). Widgets can be **reordered by drag and
  drop**; full-width and half-width widgets keep their width; the order is remembered. Widths
  (owner): Net worth and Income vs expenses full; Monthly budget, Monthly expenses, Monthly
  income and Debts half.
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
- `R-MGMT-3` Budget editor: total + currency, per-category limits each with its own currency,
  unallocated row; a red trash button removes a category limit.
- `R-MGMT-4` Events: CRUD, archive.
- `R-MGMT-5` Exchange rates (`R-FX-5`).
- `R-MGMT-6` Rules: list, edit (conditions + action, Saldo-style), delete, "Update existing
  transactions" on save (`R-IMP-8`).
- `R-MGMT-8` Lists (v1.6): category and account pickers everywhere are A–Z (accounts grouped
  by account group). The Categories page has a sort selector — Name A–Z, Name Z–A, Custom order
  (drag and drop), Newest first, Oldest first — and search. Drag a row between rows to reorder
  (Custom order), onto a row to make it a subcategory (one level), like Reminders. Only a "New
  category" button. With a category selected, "New transaction" starts with that category.
  "Uncategorised" is one built-in entry pinned at the top of Categories with an editable colour;
  transactions without a category, the donut and filters use it, one spelling (D47).
- `R-MGMT-9` Accounts (v1.6, D48): **account groups** as folders (no money of their own; sum of
  their accounts in the display currency); drag onto a group to move in, between rows to
  reorder; search; sort Name A–Z / Z–A / Custom; currency filter; net worth widget shows the same
  hierarchy.
- `R-MGMT-10` Forms: the primary action (Save / Save & apply / Confirm) is at the **bottom-right**
  of every form, inspector and sheet, Revert/Cancel left of it; never in the window toolbar.
- `R-MGMT-11` Search: a full-width search field above the filters on Transactions, Events,
  Accounts, Categories and Rules (no toolbar search). Rules filter by category (not account).
- `R-MGMT-7` Colours: categories, accounts and events get a random distinct colour when created
  (and existing grey/uncoloured ones once); the colour can be changed manually. Transaction icons
  use their category's colour everywhere and follow a colour change immediately. A category has
  the same colour on every screen (donut, budget, lists).

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
- `R-IMP-8` **Rules** (v1.5, Saldo-like). Conditions: one description condition — *exactly
  matches* or *contains* — AND optionally one amount condition — *bigger than* or *smaller than*,
  on the absolute amount in the account's currency — and optionally "only on account X".
  Actions: **assign category Y**, or **turn into a transfer** between the transaction's own
  account and account Y (outgoing money → to Y, incoming → from Y; e.g. description contains
  "Kitty" → transfer to the personal-debt account "Kitty"). Rules are created manually or from
  the user's choices in the import preview (learned rules are *contains*), apply to later imports
  and to the editor's suggestion; saving a rule with "Update existing transactions" applies it to
  matching past transactions. Text matching folds case, diacritics and whitespace.
  v1.6: a rule needs at least one condition — a description condition, an amount condition, or
  both (at most one of each). An applied rule can be **rolled back** from the rule editor
  (restores the transactions it changed).

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
- `R-SET-4` **Automatic snapshots (N1):** a snapshot of the database is taken into the Backups folder on launch
  when the newest is older than 24 h, and before any migration runs on an existing database. Retention: the
  newest of each of the last 14 days and 6 months, and the last 3 of each safety kind (pre-migration, before an
  MCP write session, before a restore). Optional second folder. Settings › Data lists snapshots with Restore
  and Back up now. Unencrypted (see `docs/status/N4.md`).

### 4.7 Reconciliation — `R-CLR` (v1.12, D74)

#### Concepts

- **Cleared** = "a bank (or the owner's former Saldo book) has confirmed this row". A bank row cannot
  disappear, so a cleared row is the part of the history the owner trusts.
- **Clearing is bookkeeping only.** It never changes balances, net worth, budgets, reports or exports.
- A **statement balance** is the closing balance printed by the bank for a statement date; the
  **cleared balance** is the account's opening balance plus the effect of cleared rows booked on or
  before that date. When the two are equal the account agrees with the bank.
- A transfer touches two accounts, so cleared is kept **per side**.


#### 4.7.1 Cleared flag — `R-CLR-1`, `R-CLR-2`, `R-CLR-3`

- `R-CLR-1` **Data.** A transaction has `isCleared` (the side on `accountID`) and `isToCleared`
  (transfers only: the side on `toAccountID`; always false otherwise). New table `reconciliations`
  (`R-CLR-5`). Shown in `R-TX-2` as "cleared". Migration **v19** (reserved), following the file's
  header rules and D18/D19:
  - `txns.isCleared INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0` and
    `txns.isToCleared INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0` (the v14/v16 pattern; each
    added only when the column is missing, so the migration can run again);
  - `CREATE TABLE IF NOT EXISTS "reconciliations"` (`id TEXT PRIMARY KEY`, `accountID TEXT NOT NULL
    REFERENCES accounts(id) ON DELETE CASCADE`, `statementDay TEXT NOT NULL`, `closingMinor INTEGER
    NOT NULL`, `correctionMinor INTEGER NOT NULL DEFAULT 0`, `finishedAt TEXT NOT NULL`) STRICT, one
    index on `accountID`. No UNIQUE, only CASCADE, plain additive columns: CloudKit-safe;
  - an index on `txns(isCleared)` is **not** added (the Reconcile query filters by account and day first).
  - Domain: `Txn.isCleared`, `Txn.isToCleared` (default false in the initialiser), a `Reconciliation`
    `@Table` struct; both `Txn` fields join the `Codable` snapshot used by `importTxnSnapshots`, with
    `decodeIfPresent` so snapshots written before v19 still decode (as uncleared).
- `R-CLR-2` **Backfill** (inside v19, one `UPDATE` per rule, in this order; a later rule never
  un-clears what an earlier one set):
  1. `isPendingAtBank = 1` → both flags 0 (a hold is not booked).
  2. `source IN ('pko','saldo')` and not pending: a non-transfer gets `isCleared = 1`; a Saldo
     transfer gets both sides; a PKO transfer gets each side whose account is the target
     (`ImportBatch.accountID`) of a batch that holds one of the transaction's fingerprints (if no
     batch names an account, the from-side). A PKO transfer whose other statement was never imported
     keeps that side uncleared.
  3. `source = 'manual'` with at least one `importFingerprints` row (it was linked to a bank row, or
     absorbed as a counterpart): the side(s) selected by rule 2's per-side test are cleared (Saldo-fingerprinted rows: both sides).
  4. `isBalanceCorrection = 1` → `isCleared = 1` (it restates the bank balance, D34, `R-ACC-4`).
  5. Everything else (hand-typed rows, debt legs without a fingerprint, duplicates) stays 0.
  `isEstimatedTransferAmount = 1` transfers keep the estimated side uncleared until a later import
  completes them (`R-CLR-7`).
  Because Saldo history is the bulk of the data, the first launch of 1.7 will show thousands of cleared
  rows and a handful of uncleared ones (hand-typed since, holds, debt legs): that is expected, and
  the pre-migration snapshot of N1 covers a rollback.
- `R-CLR-3` **Semantics.**
  - An attached record (`R-TX-6`) has no flag of its own: it follows its parent. The effect on an
    account is the parent's whole effect (main ± attached), cleared or not as one.
  - Amounts are in the account currency: the charged amount for a foreign purchase (`R-CUR-4`), the
    sent amount on the from-side and the received amount (`toAmountMinor`) on the to-side of a
    transfer. The statement is in the account currency, so no conversion happens in a reconciliation.
  - A refund or reversal counts with the sign of its flow (money in), like a balance.
  - Editing a cleared row's amount, date, account or type asks "This row is confirmed by the bank.
    Changing it will make the reconciled balance differ" and keeps the flag (the owner may be fixing
    a typo). Duplicate and "Convert to debt record" produce uncleared rows. Moving an import batch to
    another account (C48) keeps the flags and moves them with the rows.
  - A row's place in time for reconciliation is its **statement day** = `bookedDay` when present, else
    its day. PKO statements are by booking day while rows are dated by purchase day (`R-IMP-PKO-4`,
    1–3 days apart); using the purchase day would give false differences around the statement date.
    Saldo and hand-typed rows have no booking day and use their own day.

#### 4.7.2 List and editor — `R-CLR-4`

- `R-CLR-4`
  - Transactions list: a narrow column left of the description with a **cleared indicator**: filled
    green check = cleared, hollow circle = uncleared, clock = pending hold, half-filled = transfer
    cleared on one side (the tooltip names which). The row shows the side of the account in view; with
    several accounts selected it shows "cleared" only when every side shown is cleared.
  - Filter group **All / Cleared / Uncleared** in the filter bar (combinable; "Clear filters" resets it).
  - **Mark cleared / Mark uncleared** for the selected rows (button and context menu), and a "Cleared"
    checkbox in the editor ("Confirmed by the bank"). Pending holds cannot be marked cleared. For a
    transfer the editor shows one checkbox per side.
  - Account window (the pop-up that edits an account): "Balance 3,481.25 · cleared 3,569.55", "Reconciled to 21 Oct 2026 · 3,569.55"
    (or "Never reconciled") and a **Reconcile** button; the Transactions toolbar has the same button
    when exactly one account is filtered.
  - Footer totals gain "Uncleared" for a single account (balance minus cleared balance).
  - **Mark settled** (button and context menu) on a selected pending hold: the payment went through, so
    it stops being pending (`isPendingAtBank = 0`) and stays uncleared until a bank row confirms it.
    It is a separate action from editing the row; it also works in bulk on several selected holds.
  - Clicking the indicator does **not** toggle it (too easy to hit while scrolling); see Q9.

#### 4.7.3 Reconcile mode — `R-CLR-5`, `R-CLR-6`

- `R-CLR-5` **Reconcile (bank, card, savings, investment and liability accounts).**
  *What it is for.* The owner compares Abacus with the bank's statement and settles every
  difference, so that the cleared part of the account is known to be right. Two numbers come from the
  bank statement and are typed in once per run:
  - **Statement date** = the last day the statement covers (the "balance as of" date printed on the
    PDF or shown in the bank's app). Abacus only looks at rows booked up to that day; later rows are
    shown dimmed and are not part of the check.
  - **Closing balance** = the balance the bank shows at the end of that day, in the account's
    currency. Abacus compares it with its **cleared balance** (opening balance + cleared rows up to
    that day). The two must agree.
  *How it is opened (entry points).* (1) Accounts → open the account (its edit window) → the **Reconcile** button next to the balance, which
  also shows the cleared balance and the last reconciliation; (2) Transactions toolbar → **Reconcile** when exactly one account
  is filtered; (3) the import's Done step: "Reconcile <account>" with the date and closing balance
  already filled from the file's last running balance (PKO); (4) a soft **"Not reconciled"** badge on
  the account row and inspector when the account has cleared rows booked after the last reconciliation
  (or was never reconciled). The badge is a hint only: no pop-up, no notification, nothing blocks.
  Besides a new import, then, reconciliation appears when the owner opens it (1, 2) or sees the badge
  (4).
  *The request.* Opening Reconcile first shows a short setup step (no data is changed): an
  explanation in two lines, the two fields with the help above, a note where the values came from
  ("Filled from the file you just imported" or "Last reconciled 21 Oct 2026"), and **Start
  reconciling**. The statement date defaults to the last reconciliation's date or, failing that, the
  account's last booked day; the closing balance is typed as the account's balance appears in
  Abacus (a credit card in debt is negative; the hint says so, Q12). The working screen then shows
  the two values as an editable header ("Change").
  *Working screen.*
  - Three figures: statement balance, **cleared balance**, **difference** = statement − cleared (red
    until 0, green at 0, with a one-line reason by sign: lower → "a payment is missing from the cleared
    rows, or a row is ticked that the bank did not book"; higher → "income or a refund is missing").
  - List: **To check** (uncleared rows with statement day ≤ the date, newest first) with a checkbox
    each and "Tick all"; **Already cleared** (collapsed; read-only unless the owner confirms
    unticking a bank-file row); **After the statement date** (dimmed). Pending holds are listed
    unticked and disabled, labelled "Pending — not on a statement", with the row action **Mark
    settled** (`R-CLR-4`). Holds older than the stale threshold (`R-CLR-8`) carry "Pending for N
    days".
  - **Ways to make the difference zero** (a help box under the figures names them; none is forced):
    1. **Tick** a row that is on the statement and in Abacus but not yet cleared (the common case:
       a hand-typed payment the bank has booked).
    2. **Add transaction** for a payment the statement has and Abacus does not: a small form (day,
       description, amount typed with a sign: "-12.50" or no sign = money out, "+5" = money in; category; the type follows the sign; a transfer is added in
       the normal editor) creates the row **already cleared** (it is on the statement) and it counts
       at once. The owner can add several during one run.
    3. **Edit** an uncleared row whose amount or day differs from the statement (inline amount and
       day), then tick it.
    4. **Delete** an uncleared hand-typed row the bank never booked (confirmation; a bank-file row is
       never deleted here).
    5. **Mark settled / delete a pending hold** that is not on the statement (the hold is not part of
       the cleared balance either way).
    6. **Balance correction** as the last resort ("Add correction X and finish", below).
  - All staged changes (ticks, added rows, edits, deletions) live in memory and change the figures
    live; **Cancel** discards them, leaving the screen with staged changes asks first, and **Finish**
    writes them in one database transaction.
  - **Finish reconciliation** is enabled only at difference 0: it sets the ticked sides cleared,
    applies the staged additions, edits and deletions, stores a `reconciliations` row, and says
    "Reconciled … N rows marked cleared". With a non-zero difference the owner may instead "Add
    correction X and finish": one `Balance correction` row (`isBalanceCorrection`, cleared, dated the
    statement day, same mechanism as D34, not income or expense).
  - **Drift.** Every time the screen opens, the last reconciliation is recomputed (cleared balance at
    its `statementDay` now vs its `closingMinor`). If they differ a red note says "The last
    reconciliation no longer adds up: … A cleared row was edited or removed since." Nothing is locked.

- `R-CLR-6` **Cash accounts (kind `cash`).** There is no bank, so the statement is a **counted
  amount** ("Count date", "Counted cash"). The compared figure is the **whole balance at the count
  date** (every row, cleared or not, with day ≤ the date), because every cash row is hand-typed; "Tick
  all up to the date" is the primary action, and Finish marks all of them cleared. A difference is
  closed with a correction row as above. Rows dated after the count date are shown dimmed.

#### 4.7.4 Clearing at import — `R-CLR-7`

- `R-CLR-7`
  - **Bank rows.** A row created from a PKO file is cleared unless it is a hold (`Blokada`), which is
    created pending and uncleared (`R-IMP-PKO-2`). **Every row created from a Saldo file is cleared**
    (the owner is migrating from Saldo; an import never deletes anything). Transfers are cleared on the
    side(s) whose account the file belongs to: both sides for Saldo, the target account's side for PKO
    (the other side only when it is also seen in a file, below).
  - **Settled hold.** A hold upgraded by a settled row (`PendingSettlement`, `R-IMP-PKO-2`) becomes
    cleared and not pending, and gets the booking day.
  - **Hand-typed row confirmed by a bank row.** A row with no exact fingerprint that `FuzzyDuplicate`
    matches to an existing transaction (the same rule as `R-IMP-4`: same account, amount, other source
    or hand-typed, ± 3 days, similar description or same day/transfer) where the existing one is
    **hand-typed and uncleared**: the preview's default action becomes **Link** (not Skip), labelled
    "Confirms your hand-typed row and marks it cleared". Linking (`R-IMP-4`) stores the fingerprint on
    the existing row, sets it cleared and fills its `bookedDay` if empty; its amount, category, note and
    other fields stay as typed. Skip and Import anyway remain available; Skip leaves it uncleared.
    A possible duplicate whose existing row is already cleared (a Saldo row) keeps the default Skip.
  - **Absorbed counterpart / completed estimate (C38).** When an import turns an existing
    transaction into one side of a transfer, or completes an estimated transfer amount, the
    side that belongs to the file's account becomes cleared; the estimate flag clears as today.
  - **Undo of the batch.** Every row that import *changed* (cleared flag set, hold settled or
    deleted, link added) is first saved in `importTxnSnapshots` with its previous flags, so Undo
    restores it uncleared/pending. Rows the batch *created* are deleted as before.
    (Today a settled hold is not tagged with the batch, so its undo is a known gap; this item closes it
    for the cleared flag by snapshotting; settling itself stays as is.)
  - **Headless** (`abacus-import`): same pipeline, same results, no extra options. Defaults:
    possible duplicates against hand-typed uncleared rows are linked (as above), stale holds are kept
    (never deleted without the owner), balance gaps are printed as warnings. `--dry-run` prints the
    counts without writing.
  - The wizard's Done step and the import history line include the clearing counts (e.g. "2 cleared · 1
    hand-typed row confirmed · 1 hold settled").

#### 4.7.5 Stale pending holds — `R-CLR-8`

PKO holds (`Blokada`) vanish from later exports; today one that is released and never settles stays
pending forever and the owner must find and delete it.

- `R-CLR-8` At preview time, for a PKO file, an existing transaction is a **stale hold** when all of:
  - it is `isPendingAtBank`, `source = 'pko'`, on the target account;
  - its value day (the transaction's day) is **at least 5 days before the file's last booked day**
    (`staleHoldDays = 5`; settled rows are booked 1–3 days after the purchase and matched within ± 3,
    so by day 5 the settled row would be in a file booked that far);
  - the file **covers** it: value day ≥ the file's first booked day − 3 (the same ± 3 window as
    `PendingSettlement`); an older hold is out of this file's reach and is left to the Reconcile list;
  - no row of the file settled it (`PendingSettlement` found no match), no row links to it
    (`FuzzyDuplicate`), and the file does not contain the same hold again (its fingerprint is not among
    the file's rows).
  *Where it appears.* The import preview's summary cards work as the tabs: All rows, New, Already
  imported, Possible duplicates, Settle pending, **Needs review**. Choosing a card shows exactly the
  rows of that card (All rows shows all, Needs review shows only what needs a decision). **Needs
  review** has its own sub-tabs: **All**, **Decisions** (the current cards), **Pending payments (N)**
  and **Balance gaps (N)** (`R-CLR-9`); each sub-tab lists only its items, "All" lists the three
  groups one after another. The card counts everything open. The former "Accounts & categories" tab
  is not shown for a PKO file: a PKO file belongs to one account, picked in "Import into", so there is
  nothing to map; it stays for Saldo files (dozens of accounts and categories) and appears for a PKO
  file only when it has counterparties to map. Each stale hold is listed as **"Pending payment not in
  the bank file"** with merchant, amount, value day, the file's last booked day and the distance in
  days, and one decision:
  - **Keep pending** — no change; raised again at the next import while it still qualifies (Q4);
  - **Mark settled** — the payment did go through: the hold stops being pending (amount, day and
    category stay) and stays **uncleared**, because no bank row confirms it; Reconcile will show it
    under "To check" until a statement does;
  - **Delete** — the transaction is removed when the import is committed;
  - **Edit** — inline amount, purchase day and a "Still pending" checkbox; saving keeps it
    **uncleared** (the file does not show it).
  *Bulk actions.* Selection works like Finder: click selects one item, **⌘ click** adds or removes one,
  **⇧ click** selects everything from the last clicked item to this one; each item also has a checkbox
  and there is "Select all" (the same on the Transactions list). A bulk bar applies **Keep pending**, **Mark
  settled** or **Delete** to the selected items (Edit is per item). The bulk bar also exists on
  Transactions for pending rows (`R-CLR-4`).
  - Decisions start **undecided**; Import is disabled until every stale hold has one ("N pending
    payments not in the file still need a decision"); **Keep all** decides them in one click. This
    follows D38 (only fully decided previews commit).
  - All decisions commit with the batch in one database transaction (`R-IMP-6`). Mark settled, Delete
    and Edit are snapshotted in `importTxnSnapshots` (the snapshot stores the whole transaction; Undo
    re-inserts a deleted one and restores an edited or settled one), so **Undo import** brings them
    back.
  - **How the owner learns whether this happens at all:** the "Pending payments" sub-tab and card
    show their count on every PKO import, including 0 ("none found"); the import history line records
    "N stale holds: a kept, b settled, c deleted, d edited"; `abacus-import` prints the count. A few
    months of history answers the question without a separate report.
  - A held transaction on a **different** account than the target, or from Saldo, is never raised.

#### 4.7.6 Balance continuity — `R-CLR-9`

PKO's `Saldo po transakcji` is the balance after each booked row; Saldo files have none (no check).

- `R-CLR-9` For a PKO file's booked rows (holds excluded; they have no balance), after parsing and
  before the preview is built:
  1. **Chain check.** Row *j* follows row *i* when `balanceAfter_i + amount_j = balanceAfter_j`
     (signed amounts). Rows are not strictly newest-first and a day holds several rows with equal
     keys (`pko-format.md`), so the check does not trust file order: it takes the rows of one booking
     day as a set, finds the order that chains from the previous day's last balance (rows match by
     `balanceAfter − amount` against the available balances, multiset-style so equal balances do not
     confuse it), and moves on. Exactly one start (the oldest row) and one end (the newest) is healthy.
  2. **Gap.** When the rows of a day cannot be chained from the previous day's closing balance, the
     tool reports a **balance gap** between the two booking days: the missing net amount =
     (next row's starting balance) − (previous closing balance), shown signed. Rows adding up to that
     amount are not in the file (e.g. an export that skipped a day, or rows the bank booked
     out of order beyond the file's window). Zero amounts, a repeated balance and reversed pairs
     (+x then −x) are chained like any other row.
  3. **File start vs the account.** The oldest row's starting balance (`balanceAfter − amount`) is
     compared with the account's cleared balance at the end of the day before the file's first booked
     day, when the account has cleared rows before it. A difference is shown as "The file starts at X
     but <account> has Y (difference D)". It is also the hint for a wrong target account (C41 §5):
     a match is shown quietly ("File start matches PKO Personal"). Skipped on a first import.
  4. **File end** (no warning): the newest row's balance and booked day are kept for the "Reconcile
     prefilled" offer (`R-CLR-5`).
  - *Where and what can be done.* The **Balance gaps (N)** sub-tab of Needs review lists each gap
    (oldest first) with a small table of the two rows around it (amount, balance after, "starts
    from"), the missing amount and a one-line advice. Each of the two rows has an action:
    **Leave** (default: it is imported as the file says) or **Remove** (the row is not imported, e.g.
    to export a corrected period and import again; it counts as skipped). "Leave all" is one click.
    A gap is a warning: it never blocks the import and needs no decision; the warning and the choice
    are kept on the import record (history shows "1 balance gap, 0 rows removed").
  - Threshold: a gap of 0.00 is not a gap; no tolerance (money is exact, `R-CUR-2`). A foreign-currency
    PKO account is checked in its own currency; the file is single-currency, so no conversion.

#### Edge cases

| Case | Rule |
|------|------|
| Multi-currency | A reconciliation is in one account currency; transfers use the account's own side amount; charged amount for foreign purchases. No FX at all. |
| Refund / reversal | Counted by flow, like the balance. Linked refunds (`refundOfID`) are independent rows with their own flag. |
| Absorbed transfer (C38) | The absorbed counterpart's flag for the file's side is set by the import and restored by its snapshot on undo. |
| Estimated transfer amount (D64) | The estimated side stays uncleared until a later import completes it; the Reconcile screen shows it under "To check" with an "estimate" badge, tickable only after a confirmation. |
| Undo import | Created rows go; changed rows (cleared, linked, held, deleted, edited) are restored from snapshots (`R-CLR-7`). Undoing an earlier batch after a later one absorbed a row stays the known open item (C41). |
| Backup / restore (R-SET-2) | Flags and `reconciliations` are in the database, so backup and restore carry them. A backup from before v19 is migrated on restore (`prepare`), so the backfill rules apply to it. N1's pre-migration snapshot is taken before v19. |
| Headless import | `R-CLR-7` last bullet. |
| Moved batch (C48) | Flags travel with the rows; the `reconciliations` of both accounts will show drift until redone, which is correct. |
| Archived / deleted accounts | An archived account keeps its reconciliations; deleting an account (only with no transactions, `R-ACC-5`) cascades them. |
| Account with no opening date / opening balance changed | The opening balance is part of every cleared balance; changing it shows as drift. |
| Hand-typed row later than the statement date | In "After the statement date", not part of the check. |
| Two hand-typed rows match one bank row | One match per existing row (D31); the second stays uncleared, shown in Reconcile. |
| Saldo-then-PKO overlap | Saldo rows are already cleared; the PKO row is a possible duplicate with default Skip (unchanged). |

### 4.8 Recurring transactions and forecast — `R-REC` (v1.13, N5, D71)

Approved defaults: `docs/status/N5-spec.md` §7 (horizon 90 days, budget not in the forecast, snapshots daily 120 days then weekly to 2 years, grace 14 days, no notifications in v1, transfers and income included, tolerance 5 %, forecast is the second tab of Upcoming, overdue counted on today, gap split shown). Schema: migration v18.

#### 4.8.1 Scheduled items — `R-REC`

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

#### 4.8.2 Matching a real transaction — `R-REC-MATCH`

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

#### 4.8.3 Subscription detection — `R-REC-SUB`

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

#### 4.8.4 Upcoming screen and widget — `R-REC-UP`

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

#### 4.8.5 Forecast — `R-REC-FC`

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

#### 4.8.6 Forecast snapshots and forecast vs reality — `R-REC-SNAP`

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

#### 4.8.7 Non-functional

- `R-REC-21` Forecast of 90 days for 30 accounts and 100 items computes in < 100 ms (pure function over
  items and balances, nothing per-day in SQL); subscription detection over 20 000 transactions
  < 1 s and runs off the main actor (R-NF-2).
- `R-REC-22` Everything is offline and local (R-NF-1); no notification in v1 beyond the sidebar badge
  and the widget (open question Q5).

### 4.9 App lock — `R-LOCK` (v1.13, N7)

Approved defaults: `docs/status/N7-spec.md` §6 (off by default, idle 5 minutes, sheets hidden in place, recovery by `defaults write` in the README). No schema change. Settings: a Security tab in Settings.


- `R-LOCK-1` **Authentication.** Unlocking uses the system's `LocalAuthentication` with the
  `.deviceOwnerAuthentication` policy: Touch ID or Apple Watch when available, otherwise (or on
  "Use Password…") the Mac login password. Each attempt uses a fresh `LAContext` with no reuse
  window. The lock stores **no secret and uses no Keychain item**; it must work unchanged with an
  ad-hoc signed build whose code identity changes on every rebuild (N4 §7).
  - Unit: `Authenticator` protocol with a fake; model never touches `LAContext` directly. Manual:
    Touch ID path, password path, on an ad-hoc build, across two rebuilds.
- `R-LOCK-2` **Off by default; Settings switch.** New Settings tab **Security** (prototype) holds the
  switch "Require Touch ID or password to open Abacus", the **Lock after** picker and **Lock now**.
  Turning the lock **on** first runs one authentication ("prove it works"); if it fails, is
  cancelled, or is unavailable the switch stays off and a message says why. Turning it **off**, and
  **increasing** the idle time, also require a successful authentication (someone at an unlocked Mac
  cannot weaken the lock without the password). Decreasing the idle time needs none.
  - Unit: enable requires `.success`; cancel/failure/unavailable leave state unchanged with the
    right message; disable and idle-increase require auth, decrease does not.
- `R-LOCK-3` **Per device, not synced, not in backups.** The setting (enabled, idle minutes) is kept
  in `UserDefaults` on this Mac, **not** in the `app_setting` table: that table is part of the
  database, which is backed up (R-SET-2), moved with the data folder and will be synced (D66). A
  restore, a data-folder change or a second device must not turn the lock on or off.
  - Unit: the lock settings store reads/writes only its `UserDefaults` suite keys
    (`appLock.enabled`, `appLock.idleMinutes`); a backup export/restore round-trip leaves them
    untouched (test against the existing `Backup` with a scratch suite).
- `R-LOCK-4` **Lock after.** Picker: 1 minute, **5 minutes (default)**, 15 minutes, 30 minutes,
  1 hour, Never (idle never locks; launch, sleep, screen lock and Lock now still do).
  - Unit: each value maps to the configured interval; unknown stored value falls back to 5.
- `R-LOCK-5` **Lock triggers** (when the lock is on): (a) **at launch**, before any content is
  shown; (b) **idle**: the time since the last user input to Abacus (key, click, scroll) reaches the
  picker value, counted also while Abacus is in the background or hidden; (c) **sleep**: system sleep
  and display sleep; (d) **screen lock and screensaver start**; (e) **Lock now**: menu item
  "Lock Abacus" (⌥⌘L, proposed) and the Settings button. A trigger while already locked does nothing
  (idempotent). The idle deadline uses a monotonic clock that keeps counting through sleep, and the
  deadline is re-checked when the app becomes active, so a missed timer cannot leave the app
  unlocked.
  - Unit (fake clock + fake event source): lock at launch; lock exactly at the deadline, not before;
    input resets the deadline; background time counts; sleep/display sleep/screen lock/screensaver/
    manual each lock; duplicate triggers produce one lock; picker "Never" disables idle only;
    deadline re-check on activation locks when overdue; trigger while an unlock prompt is open
    cancels the prompt and stays locked. Manual: each real trigger on the built app.
- `R-LOCK-6` **First launch after turning it on is not locked.** Enabling authenticates already; the
  window stays usable and the idle clock starts.
  - Unit: enabling leaves state unlocked and sets `lastInput = now`.
- `R-LOCK-7` **Lock screen.** An opaque view covers the whole window (prototype): lock icon, "Abacus
  is locked", the reason ("Locked after 5 minutes idle."), an **Unlock** button, **Quit Abacus**,
  and a one-line note. When the lock appears and Abacus is the active app it **asks to authenticate
  once automatically**; it does not re-prompt in a loop. After a cancel it shows "Unlock was
  cancelled. Click Unlock to try again." and waits. It prompts again when the user clicks Unlock, and
  once more when Abacus becomes active again after having been inactive while locked (no prompt
  while asleep or the screen is locked). On success the previous screen reappears exactly as left
  (section, filters, scroll, open import wizard). Standard Quit (⌘Q) works while locked.
  - Unit: state machine `locked → prompting → (unlocked | cancelled | failed | unavailable)`;
    exactly one automatic prompt per lock and per activation; no prompt while the screen is locked
    or asleep; success returns `unlocked`. Manual: screenshots of each state against the prototype.
- `R-LOCK-8` **Authentication fails or is unavailable.** *Cancelled* (`userCancel`, `systemCancel`,
  `appCancel`): stays locked, "cancelled" message, Unlock button. *Failed* (wrong password; the system
  dialog normally handles retries, an `authenticationFailed` result is shown as "That didn't work"):
  stays locked. *Unavailable* (`canEvaluatePolicy` false or an error such as `passcodeNotSet`,
  `notInteractive`, anything unexpected): stays locked, shows "Authentication isn't available right
  now…" with **Try again** and **Quit Abacus**. **There is no bypass or "turn the lock off" button on
  the lock screen**: a bypass would make the lock meaningless. Recovery if the owner is locked out
  of the system method for good: quit and set the preference from Terminal
  (`defaults write <bundle id> appLock.enabled -bool NO`), documented in the README. This is
  acceptable because the lock is only a UI gate and the owner owns the Mac (N4 §7).
  - Unit: each `LAError` code maps to the right state and message; unavailable never unlocks;
    unknown errors are "unavailable"; Try again re-queries availability.
- `R-LOCK-9` **What is hidden while locked.** Everything the app draws: the main window and the
  Settings window (both show the lock screen); the window contents seen in **Mission Control /
  Exposé thumbnails** and screenshots (they show the lock screen because it is composited into the
  window itself); any **sheet or alert** (`R-LOCK-11`); the **menu bar**: items that open, create,
  import, export, back up, restore or otherwise act on data are disabled (no menu shows data in the
  first place); **window titles** and the Window menu never contain data (titles stay "Abacus");
  **keyboard input** is not delivered to the hidden screens (shortcuts such as ⌘N do nothing). The
  **Dock icon** is the normal icon with no badge, and the **app switcher** (⌘Tab) shows only the
  icon, so neither leaks content. If macOS's saved window state turns out to store window images,
  restorable state is disabled for the window (spike item, §1).
  - Unit: `LockModel.isLocked` drives a `commandsEnabled` value that is false while locked (tested
    on the model). Manual checklist: Mission Control, ⌘Tab, Dock, a screenshot, VoiceOver reading
    the window (the hidden screens are not in the accessibility tree: `.accessibilityHidden`), ⌘N and
    ⌘, while locked, Window menu.
- `R-LOCK-10` **Honest scope, stated in the UI.** The Security tab says: the lock hides the
  window; it does not encrypt data; the database file stays readable by other apps and tools; the
  **MCP server (`abacus-mcp`) and `abacus-import` are separate processes that open the file directly
  and are **not** gated** by the lock; FileVault protects the disk. The README says the same. This
  is **not database encryption**: that was researched in N4 (decision: FileVault now; SQLCipher only
  after Developer ID signing, with the key obtained at unlock). Nothing in N7 may be described as
  "encrypted".
  - Unit: none (text). Manual: wording check against this section.
- `R-LOCK-11` **Open editors, sheets and unsaved edits.** Locking never discards work. While locked,
  attached sheets (transaction editor, account/category sheets, confirmation dialogs) are hidden and
  ignore input, and come back with their unsaved edits unchanged after unlock. Recommended
  mechanism (spike first): at lock, hide every attached sheet window of the app's windows (alpha 0,
  ignore mouse events) and restore it at unlock; the views underneath stay mounted, disabled and
  hidden from accessibility. Fallback if that is unreliable: dismiss the sheet after saving its draft
  in memory and reopen it with the draft after unlock. System **open/save panels** (for example
  "Choose file…" in the import wizard) are separate system UI and may stay on screen; they show file
  names, not Abacus data (accepted, listed under open questions).
  - Unit: the draft-stash fallback (if used) round-trips a draft. Manual: lock with the editor
    open and a typed amount, unlock, the sheet and the typed text are back; same for the import
    wizard at "Review" and for a confirmation dialog.
- `R-LOCK-12` **Background work continues.** Locking does not cancel or pause an import, a rate
  refresh, a backup (N1) or a headless MCP write. Their outcome is shown after unlock in the usual
  places; while locked, **no alert, sheet, notification or Dock bounce carries data** (a generic
  "Abacus finished a task" is allowed only if it contains no amounts, names or counts). An import
  wizard in progress keeps its state (`R-LOCK-11`). Database access, the repositories and `AppSession`
  are unchanged by the lock.
  - Unit: locking while a fake long task runs leaves it running; the task's completion while locked
    queues its message and delivers it on unlock. Manual: start an import, let it lock, unlock.
- `R-LOCK-13` **Architecture hook (N4 §7).** Lock state is an app-level model (`AppLockModel`:
  `isLocked`, `state`, `reason`) owned beside the session host and independent of the database: the
  database is opened as today and **not** lazily at unlock. A later encryption step may add an
  "on unlock" step (fetch a key, then open) without changing the lock UI. The model sees time, input
  and system events only through injected protocols (`Authenticator`, `Clock`,
  `LockEventSource`), so it is fully unit-testable and a launch flag can run the UI with a fake
  authenticator for screenshots.
  - Unit: the whole `R-LOCK-5…8` suite above, with fakes.

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
Per-category budget rollover · tags
("cleared" flag, statement balance check) · CSV export · more bank
formats (Monobank, Revolut) · rates and charged-amount pre-fill for purchase currencies beyond
the four (D24).

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

| Q23 | Saldo cross-currency transfer halves with different in-transit currencies are **not** paired automatically; they stay in Needs review (manual pairing there). |

No open questions.

## 10. Change log

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-10-21 | Agreed baseline. |
| 1.1 | 2026-10-21 | `R-HOME-1`: net worth is a monthly chart ending at today (owner's prototype review); removed from backlog. |
| 1.7 | 2026-10-27 | Debts (`R-DEBT`, owner interview, D51). |
| 1.11 | 2026-10-30 | Refund links (`R-TX-4`), import bulk assignment and Category assignment tab, category re-assign and show-transactions, searchable category pickers, rule kind select and debt picker. |
| 1.13 | 2026-11-17 | Recurring transactions, subscriptions, upcoming bills, forecast and forecast snapshots (`R-REC-1…22`, §4.8, migration v18); app lock (`R-LOCK-1…13`, §4.9). Recurring removed from out of scope and backlog. |
| 1.12 | 2026-11-03 | Reconciliation (`R-CLR-1…9`, §4.7, migration v19, D74): cleared flag per transaction side, Reconcile screen, stale pending holds and balance gaps at import; automatic snapshots (`R-SET-4`, N1). |
| 1.10 | 2026-10-30 | Owner testing of 1.4.0: one total on widget and rows (`R-DEBT-21a`); debt filter chip and accounts menu rules (`R-DEBT-22`). |
| 1.9 | 2026-10-30 | Accounts drive debts: one debt per person without currency, linked external/virtual accounts, transfers instead of record legs, edit/rename, debt filter on Transactions, sign display, widget (`R-DEBT-16…22`, D59–D61). |
| 1.8 | 2026-10-30 | Debts linked to bank transactions: one payment one transaction, import action, convert, rule action, matching, several accounts, currency switch (`R-DEBT-9…15`, D58). |
| 1.6 | 2026-10-27 | Owner review of 1.1.0: budget total + currency back with unallocated (`R-BUD-1`, `R-MGMT-3`); built-in Uncategorised, sorting/search/drag-to-nest for categories (`R-MGMT-8`); account groups (`R-MGMT-9`); form button placement (`R-MGMT-10`); page search (`R-MGMT-11`); rules: amount-only condition, rollback; income donut, income vs expenses, widget reorder (`R-HOME-6`); currency switch order and Budget page; debts: design pending (owner interview). |
| 1.5 | 2026-10-27 | Owner review of v1.0.0: per-category budget currencies, no separate total (`R-BUD-1/2`, `R-MGMT-3`); Saldo-like rules with amount conditions and a transfer action (`R-IMP-8`, `R-MGMT-6`); colours for categories, accounts, events (`R-MGMT-7`, `R-EVT-1`); click-only drill-down (`R-HOME-3`); budget edit button (`R-HOME-2`); currency switch only where it applies (`R-HOME-4`). |
| 1.4 | 2026-10-21 | Q23: no second Saldo pairing pass; cross-currency halves go to Needs review. |
| 1.3 | 2026-10-21 | Q22: PKO rows dated by the purchase day, booking day kept (`R-IMP-PKO-2`, new `R-IMP-PKO-4`). |
| 1.2 | 2026-10-21 | Editor review: currency picker replaces "paid in another currency" (`R-CUR-4`, `R-EDIT-4`); last-used currency/account and transfer accounts as defaults (`R-EDIT-4/5`). |
