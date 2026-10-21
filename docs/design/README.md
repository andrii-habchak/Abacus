# Screen prototypes (WP D1)

Interactive macOS-styled prototypes, reviewed by the owner one group at a time. A B-lane builds a
screen only after its group is **approved** here. The prototypes use synthetic data only.

The live canvas is the owner's private "Abacus prototypes" page; each approved artboard's
source is copied into this folder (`<n>-<name>.dc.html`).

| # | Group | State | Notes |
|---|-------|-------|-------|
| 1 | Shell + Dashboard | **approved** 2026-10-21 | Net worth changed to a monthly chart ending today (TA 1.1, `R-HOME-1`) |
| 2 | Transaction list + filters | **approved** 2026-10-21 | |
| 3 | Editor (3 types, attached records, event) | **approved** 2026-10-21 | With the currency picker and last-used defaults (TA 1.2) |
| 4 | Accounts / Categories / Budget / Events / Rules | **approved** 2026-10-21 | |
| 5 | Import wizard | **approved** 2026-10-21 | |
| 6 | Rates + Settings | in review | |

## Approved decisions per screen

### 1 · Shell + Dashboard
- Sidebar: Overview (Dashboard, Transactions, Events), Manage (Accounts, Categories, Budget,
  Import, Exchange rates, Rules), Settings at the bottom.
- Toolbar: title, "NBU rates · <date>", display-currency segmented control (UAH/PLN/EUR/USD),
  "New transaction".
- Net worth: headline = today; change since last month-end; 12-month line chart (month-end
  points, hover shows a month); assets / liabilities; "Show accounts" table (native balance +
  converted); note that archived accounts are excluded.
- Month selector (‹ month ›) shared by Budget and Expenses; next disabled at the current month.
- Monthly budget: spent of total, bar, remaining + % used, status badge ("On track" / "N
  categories over"); per-category bars — blue ok, amber ≥ 90 %, red over with "Over by X";
  "Unallocated (other categories)" row.
- Monthly expenses: donut by category + legend (amount, %); clicking a slice/legend row selects
  it and drills down to Transactions filtered by category + month.

### 2 · Transactions
- Toolbar: search (description + note), display-currency control, "New transaction".
- Filter bar: date preset menu (Last 30 days default, This month, Last month, Last 3 months,
  This year, custom From/To); Categories multi-select (parent "(all)" covers its children);
  Accounts multi-select; Type toggles Expense / Income / Transfer; Event menu; "Clear filters"
  when anything differs from the default; sort button Newest first / Oldest first.
- Active filter chips are highlighted blue.
- List: column header (Description, Category, Account, Amount); rows grouped by day with the
  day's net in the display currency; row = category tile, description + badges (Pending, Refund,
  event), note · time, "Parent › Child" category, account, amount in the account currency
  (income/refund green) with "Charged €10.00" for foreign purchases; transfers show
  "From → To" and the received amount; attached records nested under their row.
- Footer: count, income, expenses, net in the display currency ("converted at each day's NBU
  rate"). Empty state: "No transactions match these filters."

### 3 · Transaction editor
- A sheet over the main window: title (New / Edit transaction; edit shows the source, e.g.
  "Imported from PKO · 5 Oct 2026"); Expense / Income / Transfer segmented control.
- Big amount with sign (− expense, + income/refund, ⇄ transfer) and a **currency picker**
  (UAH, PLN, EUR, USD, CHF, CZK, GBP, HUF); transfers use the From account's currency.
- New transaction: currency and account from the **last transaction**; new transfer: From/To from
  the **last transfer**; a hint says so until the user changes them.
- "Refund (money came back)" / "Reversal (money went back out)" checkbox.
- Expense/Income: Account; "Charged to account" (only when the currency differs; pre-filled at
  the NBU rate, editable); Category (subcategories indented) with "Suggested by rule “x” → Y"
  until the user picks one.
- Transfer: From, To (error when equal), "Amount received" + implied rate when currencies differ.
- Common: Description, Date + time, Event (pre-selected while an event is active, with a hint),
  Note.
- "Fees, cashback and split lines": Add fee / Add line; each line = Expense|Income, category,
  amount, note, remove. Summary "Effect on <account>" = main ± lines, in the account currency.
- Footer: Delete… and Duplicate (edit only), ⏎ Save · ⎋ Cancel hint, Cancel, Save (disabled
  until valid).

### 4 · Accounts, Categories, Budget, Events, Rules
- Accounts: grouped list (group name), liabilities red, "Show archived accounts"; inspector with
  name, kind (Assets / Liabilities groups), currency (fixed after the first transaction),
  opening balance + date, group, IBAN, current balance; Archive… (non-zero balance → "Its
  balance is X, not zero… Archive anyway?"), Unarchive; Delete disabled with "Has N
  transactions — archive it instead".
- Categories: Expense / Income tabs; tree (parents bold, children indented), drag handle, usage
  count; inspector with name, parent, colour swatches, usage; Archive; Delete… → reassign
  dialog (same-kind target for transactions and budget limit) with "Archive instead".
- Budget: total + currency, "Applies from <month>" (earlier months unchanged); per-category
  limits with share bars, "incl. <children>" for parents; Unallocated row (red with "Limits
  exceed the total by X"); add/remove category limits; Save budget.
- Events: list (dates or "No dates (ongoing)", spent vs budget); inspector with dates, optional
  budget, auto-tag note, spent by category, "Show N transactions", Archive, Delete….
- Rules: "Try a description" tester highlighting the first matching rule; table with enable
  toggle, "description contains" pattern, account, category, origin (learned from an import /
  manual), hit count; first match wins.

### 5 · Import wizard
- Toolbar: step indicator (1 Choose file · 2 Review · 3 Done), History, Choose file….
- Step 1: drop zone for a CSV; format detected automatically (Saldo / PKO BP); nothing saved
  until confirmed.
- Step 2: file bar (name, detected format, rows, date range; PKO: "Import into <account>",
  remembered). Summary cards that also filter: All rows, New, Already imported (skipped
  automatically), Possible duplicates (skipped unless chosen), Settle pending, Needs review.
  Tabs:
  - Transactions: status badge, date, description + detail, account, amount, category picker
    ("By rule “x”" / "Needs a category" / "Will be saved as a rule"); possible duplicates get
    Skip (default) / Import anyway / Link to existing; transfers "no category".
  - Accounts & categories: source → existing or "Create …" (remembered mappings marked);
    Saldo liabilities → Debt, archived → created archived; PKO counterparties by IBAN, ATM →
    cash account.
  - Events from tags (Saldo): tick tags to create events.
  - Needs review: per item radio — Pair with <candidate> / Record as expense|income
    (+ category) / Skip; PKO unknown operation types.
  - Footer: uncategorised count, rules to be saved, "All or nothing", Cancel, Import N.
- Step 3: summary lines, Undo this import, Show transactions.
- History panel: batches with counts, "Undo import…", undone ones greyed.
