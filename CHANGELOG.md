# Changelog

All notable changes to Abacus. Versions follow [Semantic Versioning](https://semver.org).

## [1.3.0] — Unreleased

Debts linked to bank transactions. Opening this version updates the database (a rule column for
debt rules); back up `abacus.sqlite` first.

### Added

- Import: "Debt…" on a row turns it into a debt record (person, debt, kind suggested from the
  direction); the imported row becomes the record's transaction.
- Import: a bank row for a payment already entered as a debt record is recognised as Already
  imported ("Linked to the debt record"), for money out and money in.
- Transactions: "Convert to Debt Record…" turns an existing expense or income into a debt record
  without a second transaction.
- Rules: new action "Record as debt for <person>", applied on import and by "Update existing
  transactions" (with Roll back).
- Debts: an Accounts card per person (money out / in per account); person totals converted to the
  display currency.

### Fixed

- A hand-entered "They repaid" or "I borrowed" record was not recognised by the import, so the
  same money could be counted twice.

## [1.2.2] — 2026-10-30

Rules and PKO import fixes. No database changes.

### Added

- Rules: a "Description starts with" condition.

### Changed

- Rules: "Description exactly matches" is now called "Description equals" (same behaviour).

### Fixed

- PKO card holds ("Pending at the bank") whose amount had no minus sign showed as income; holds
  are always expenses now, and settling a hold repairs one stored with the wrong sign.

## [1.2.1] — 2026-10-27

Stability and the owner's review of 1.2.0. No database changes beyond 1.2.0.

### Fixed

- Crashes on Escape, on saving, cancelling or forgiving in Debts, and after drag and drop
  (forms read a draft that had just been cleared).
- A double Return could save a debt record twice.
- Fee and split lines in the transaction editor could read a removed line.
- Slow dashboard and lists: day/month comparisons no longer format strings (dashboard reload
  about 5× faster); a drop refreshes only the order instead of reloading everything.
- Budget showed "Unsaved changes" after a successful save.

### Changed

- Accounts and Categories use a native outline list: a line between rows reorders, a
  highlighted row nests, auto-scroll while dragging. Dropping an account onto an ungrouped
  account creates a group with both.
- Creating and editing accounts, groups and categories happens in a pop-up sheet.
- "New account" is a split button with "New account in <group>" and "New group…".
- New transaction starts on the selected account (Accounts) or category (Categories).
- Budget Save button: blue when there are edits, green "Saved" after saving.
- Rules page: the "Try a description" row is removed.

## [1.2.0] — Unreleased

Changes from the owner's review of 1.1.0. Opening this version updates the database (rule
rollback history, category creation dates, debts, account groups); back up `abacus.sqlite` first.

### Added

- **Debts**, separate from accounts: a person and a currency per debt; records I lent, They
  repaid, I borrowed, I repaid, Paid on their behalf, Forgive; optional "Count as expense / income"
  and "Count in net worth"; due date, note, settled. Debts tab and a dashboard Debts widget.
  Existing debt accounts become debts with their history; account balances and net worth stay
  the same.
- **Account groups** (Monobank, PKO, …) as folders with their total; drag accounts in and out;
  search, sort and currency filter on Accounts; pickers list accounts A–Z under their groups; the
  net worth breakdown shows groups.
- **Dashboard**: Monthly income donut, Income vs expenses (12 months), drag-to-reorder widgets.
- **Categories**: sort selector (Name A–Z / Z–A, Custom order, Newest / Oldest first), search,
  drag onto a category to make a subcategory; a built-in "Uncategorised" with its own colour.
- **Rules**: conditions on the amount alone; Roll back an applied rule (also after a restart);
  search and category filter.
- **Budget**: a total with its own currency again, with Unallocated; the page follows the
  currency switch.

### Changed

- Search fields sit above the filters on Transactions, Events, Accounts, Categories and Rules.
- Save buttons are at the bottom-right of every form.
- Currency switch order EUR, USD, PLN, UAH; no "New transaction" on Budget and Rules.
- Category pickers are A–Z everywhere except the Categories page.
- A category has the same colour on every screen.
- Removing a budget limit uses a red trash button.

### Fixed

- Rule "Save & apply" did not update existing transactions.
- Budget edits were lost when switching screens before saving.
- An event's "Show transactions" missed transactions outside the event's dates.
- Transaction type filter labels wrapped mid-word.
- The dashboard opened scrolled to the bottom with Full Keyboard Access on.

## [1.1.0] — Not released (test build)

Changes from the owner's review of 1.0.0. Opening this version updates the database (colours,
budget currencies, rules); back up `abacus.sqlite` first.

### Added

- **Colours** for categories, accounts and events: a random distinct colour for new ones and once
  for existing uncoloured or grey ones; palette swatches and a custom colour in each editor.
- **Budget limits in any currency per category** (e.g. Groceries 400 EUR, Home 5 747 PLN). The
  total is the sum of the limits in the display currency.
- **Rules like Saldo's**: description *exactly matches* or *contains*, optionally AND amount
  *bigger than* / *smaller than*, optionally one account; action *assign category* or *transfer
  to/from an account*. "Update existing transactions" applies a rule to past transactions after
  a confirmation, with Undo.
- Edit button on the dashboard's budget widget, opening the Budget screen.

### Changed

- Transaction icons use their category's colour and follow a colour change immediately.
- The display-currency switch shows only on Dashboard, Transactions, Accounts and Events.
- The budget has no separate total or "unallocated" remainder any more.

### Fixed

- The app no longer switches to Transactions on its own: hovering the expenses donut only
  highlights a slice; a click opens the transactions.

## [1.0.0] — 2026-10-27

First release: the macOS app, ad-hoc signed, distributed as a DMG.

### Added

- **Accounts** in UAH, PLN, EUR and USD: cash, bank account, card, savings/deposit and
  investment assets; credit card, loan and personal debt liabilities. Groups, opening balance
  and date, optional IBAN for recognising own transfers, archive (excluded from net worth) and
  delete when unused.
- **Transactions**: expense, income and transfer (also across currencies, with the implied
  rate); refunds; attached lines for fees, cashback and splits; any ISO currency with the amount
  charged to the account; pending-at-the-bank flag; edit, duplicate, delete. The editor is
  keyboard-first, suggests a category from the description and starts with the last used
  account, currency and transfer accounts.
- **Categories** for income and expense with one level of subcategories, reordering, and
  reassign-or-archive when deleting one in use.
- **Monthly budget**: a total in any of the four currencies split across categories, repeating
  every month until changed; over-limit and near-limit categories highlighted.
- **Events** (trips, projects) that group spending across categories, with an optional date
  range and budget.
- **Dashboard**: net worth with a 12-month chart and per-account breakdown, the month's budget,
  a monthly expenses donut that opens the matching transactions, month selector and display
  currency switch.
- **Transaction list**: grouped by day, filters by date range, category, account, type and
  event, text search, sort order, and totals in the display currency.
- **Import** of Saldo CSV exports and PKO BP "Zestawienie operacji" CSV statements with a preview
  before saving: account and category mapping (remembered), exact de-duplication by fingerprint,
  possible-duplicate detection across sources, a needs-review queue, Saldo transfer pairing and
  tags as events, PKO pending holds upgraded when they settle, categorisation rules learnt from
  your choices, import history with undo.
- **Categorisation rules** screen: list, edit, enable/disable, delete.
- **Exchange rates**: official NBU rates (Frankfurter API, NBU API as fallback) fetched on launch,
  daily and on demand, cached for offline use; history per day for period totals; manual rates
  for a day or from a day on; a rates screen with a 30-day trend.
- **Settings**: default display currency, "Refunds reduce category spending", automatic rate
  updates, the data folder location, backup export and restore.
- **Help › Load Sample Data** for a demo on an empty database.
- App icon; `scripts/build-dmg.sh` builds the release DMG locally.
