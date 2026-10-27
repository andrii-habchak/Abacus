# Changelog

All notable changes to Abacus. Versions follow [Semantic Versioning](https://semver.org).

## [1.1.0] — Unreleased

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
