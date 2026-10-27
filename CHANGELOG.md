# Changelog

All notable changes to Abacus. Versions follow [Semantic Versioning](https://semver.org).

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
