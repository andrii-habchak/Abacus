# Abacus

A personal finance tracker for macOS. Abacus keeps your accounts in UAH, PLN, EUR and USD in one
place, converts everything at official National Bank of Ukraine (NBU) rates, and gets most of
your history in by importing files instead of typing them: a Saldo export and PKO BP bank
statements.

Everything is stored on your Mac. There are no bank connections, no accounts to sign up for and
no telemetry; the only network traffic is fetching exchange rates.

![Dashboard](docs/screenshots/dashboard.png)

## Features

- **Dashboard**: net worth with a 12-month chart and a breakdown by account group, the month's
  budget, monthly expense and income donuts (click a slice to see its transactions), income vs
  expenses for the last 12 months, and your debts. Drag widgets into the order you like. Switch
  the display currency (EUR, USD, PLN, UAH) at any time.
- **Accounts**: cash, bank accounts, cards, savings, investments, credit cards and loans, with
  opening balances, in **groups** (Monobank, PKO, …) that show their total. Drag an account into
  a group, or onto another account to make a new group. Search, sort and filter by currency;
  archive old accounts to keep their history out of net worth.
- **Transactions**: expenses, income and transfers (also between currencies), refunds, and
  attached lines for fees, cashback or splitting one payment across categories. You can pay in
  any currency and record what the account was actually charged. Pending bank holds are marked
  until they settle.
- **Transaction list**: last 30 days by default, grouped by day, with search, filters for date,
  category, account, type and event, and income / expense / net totals for what you see.
- **Categories** with one level of subcategories and their own colours: drag one onto another
  to nest it, sort by name, custom order or date, and search. Transactions without a category
  share one built-in "Uncategorised".
- **Budget**: a monthly total in any currency plus category limits, each in its own currency,
  with what's left unallocated. **Events** (a trip, a move, the car) collect spending across
  categories.
- **Debts**: who owes you and whom you owe, per person and currency: lent, repaid, borrowed,
  paid on their behalf, forgiven. Choose per record whether it counts as an expense or income,
  and per debt whether it counts in net worth.
- **Import** with a preview before anything is saved: Saldo CSV exports (accounts, categories,
  transfers and tags as events) and PKO BP "Zestawienie operacji" CSV statements. Re-importing an
  overlapping file never creates duplicates, likely duplicates from other sources are flagged,
  and any import can be undone.
- **Rules** like "description contains *biedronka* → Groceries" or "amount bigger than 100 →
  transfer to an account", learned from your import choices or written by hand. Apply a rule to
  existing transactions and roll it back if it was wrong.
- **Exchange rates**: official NBU rates fetched on launch and daily, cached for offline use,
  with a 30-day history per currency. Set a manual rate for a day, or from a day on, when your
  bank charged something else.
- **Settings**: default display currency, how refunds are counted, automatic rate updates, the
  data folder, and backup export / restore.

The full functional description is in the [tech assignment](docs/REQUIREMENTS.md).

## Screenshots

All screenshots show the built-in sample data: made-up accounts, people and amounts.

<table>
  <tr>
    <td align="center" valign="top">
      <img src="docs/screenshots/dashboard-dark.png" alt="Dashboard in dark mode" width="420"><br>
      <sub>Dashboard, dark mode</sub>
    </td>
    <td align="center" valign="top">
      <img src="docs/screenshots/transactions.png" alt="Transaction list with search and filters" width="420"><br>
      <sub>Transactions</sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top">
      <img src="docs/screenshots/accounts.png" alt="Accounts in groups with their totals" width="420"><br>
      <sub>Accounts and groups</sub>
    </td>
    <td align="center" valign="top">
      <img src="docs/screenshots/categories.png" alt="Categories with subcategories and colours" width="420"><br>
      <sub>Categories</sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top">
      <img src="docs/screenshots/budget.png" alt="Monthly budget with a total and limits in several currencies" width="420"><br>
      <sub>Monthly budget</sub>
    </td>
    <td align="center" valign="top">
      <img src="docs/screenshots/debts.png" alt="Debts per person and currency with records" width="420"><br>
      <sub>Debts</sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top">
      <img src="docs/screenshots/rules.png" alt="Rules with description and amount conditions" width="420"><br>
      <sub>Rules</sub>
    </td>
    <td align="center" valign="top">
      <img src="docs/screenshots/import.png" alt="Import, step 1: choose a Saldo or PKO file" width="420"><br>
      <sub>Import, step 1</sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top">
      <img src="docs/screenshots/rates.png" alt="Exchange rates with 30-day history and manual rates" width="420"><br>
      <sub>Exchange rates</sub>
    </td>
    <td align="center" valign="top">
      <img src="docs/screenshots/settings-general.png" alt="Settings, General tab" width="420"><br>
      <sub>Settings › General</sub>
    </td>
  </tr>
</table>

## Requirements

- macOS 26 or later (Apple silicon or Intel).

## Install

1. Get `Abacus-<version>.dmg`: from the repository's **Releases** page when a release is
   published, or build it yourself (see [Building from source](#building-from-source)).
2. Open the DMG and drag **Abacus** to **Applications**.
3. The app is **ad-hoc signed and not notarized**, so Gatekeeper blocks the first launch. Either
   right-click **Abacus.app › Open** once and confirm, or clear the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Abacus.app
   ```

**Updating**: quit Abacus, then replace the app. A new version may update the database on its
first launch, so back up `~/Library/Application Support/Abacus/abacus.sqlite` first (or use
Settings › Data › Export backup).

To check the download, compare `shasum -a 256 Abacus-<version>.dmg` with the published
`.sha256` file.

## First steps

Abacus starts empty. Pick one:

- **Import a Saldo export**: in the Saldo app, export your data as CSV, then in Abacus open
  **Import** (sidebar), choose or drop the file, review the preview and click Import. Accounts,
  categories and opening balances are created for you; transfers recorded as two halves are paired.
- **Import a PKO BP statement**: in PKO BP online banking, export the account history as CSV
  ("Zestawienie operacji"), then import it the same way and pick the Abacus account it belongs to
  (remembered for next time). Import newer statements whenever you like: rows already imported
  are skipped and pending card holds are updated when they settle.
- **Just look around**: **Help › Load Sample Data** fills an empty database with synthetic
  accounts, transactions, a budget, events and debts. It does nothing if you already have data.

Then add transactions by hand with **New transaction** (⌘N). Sections are on ⌘1…⌘0, Refresh
Rates is ⌘R, Settings is ⌘,.

## Your data

- **Location**: one SQLite database in
  `~/Library/Application Support/Abacus/abacus.sqlite` (with its `-wal` and `-shm` files).
  **Settings › Data › Show in Finder** opens the folder.
- **Backup**: **Settings › Data › Export backup…** writes all your data to a single
  `.abacus` file; keep it somewhere safe (another disk, a cloud folder). **Restore from backup…**
  replaces everything in the app with the backup's contents, after asking you to confirm.
  Time Machine also backs up the database folder.
- **Privacy**: data never leaves your Mac. The only network requests are for exchange rates:
  NBU rates via the Frankfurter API (`api.frankfurter.dev`) with the NBU's own API
  (`bank.gov.ua`) as a fallback. Turn off automatic updates in **Settings › Rates** to fetch
  only when you click Refresh rates.

## Building from source

Requirements: Xcode with the macOS 26 SDK (built and tested with Xcode 27), and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from [`project.yml`](project.yml);
the generated `Abacus.xcodeproj` is committed, so you can also just `open Abacus.xcodeproj`.
If `xcode-select` points at the Command Line Tools, prefix the commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
# Release DMG: generates the project, builds an ad-hoc signed Release,
# writes dist/Abacus-<version>.dmg and prints its SHA-256
scripts/build-dmg.sh

# Core package: build and run all tests (from AbacusKit/)
cd AbacusKit && swift test && cd ..

# Regenerate the Xcode project after changing project.yml
xcodegen generate --spec project.yml

# Debug build of the app (macros need -skipMacroValidation on the command line)
xcodebuild -project Abacus.xcodeproj -scheme Abacus -destination 'platform=macOS' \
  -derivedDataPath build.noindex -skipMacroValidation build
```

The app is a thin SwiftUI shell (`App/macOS`); domain, currency math, storage, importers and
view models live in the local Swift package [`AbacusKit`](AbacusKit).

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## Project docs

- [Tech assignment](docs/REQUIREMENTS.md): requirements with stable `R-…` IDs.
- [Execution plan](docs/PLAN.md) and [status](docs/STATUS.md).
- [Decisions](docs/DECISIONS.md).
- [Screen designs](docs/design/README.md).
- Import formats: [Saldo](docs/import/saldo-format.md), [PKO BP](docs/import/pko-format.md).
- [Contributor guide](AGENTS.md): working rules, build facts and the code map.
