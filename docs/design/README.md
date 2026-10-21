# Screen prototypes (WP D1)

Interactive macOS-styled prototypes, reviewed by the owner one group at a time. A B-lane builds a
screen only after its group is **approved** here. The prototypes use synthetic data only.

The live canvas is the owner's private "Abacus prototypes" page; each approved artboard's
source is copied into this folder (`<n>-<name>.dc.html`).

| # | Group | State | Notes |
|---|-------|-------|-------|
| 1 | Shell + Dashboard | **approved** 2026-10-21 | Net worth changed to a monthly chart ending today (TA 1.1, `R-HOME-1`) |
| 2 | Transaction list + filters | in review | |
| 3 | Editor (3 types, attached records, event) | not started | |
| 4 | Accounts / Categories / Budget / Events / Rules | not started | |
| 5 | Import wizard | not started | |
| 6 | Rates + Settings | not started | |

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
