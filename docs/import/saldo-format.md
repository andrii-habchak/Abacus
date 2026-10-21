# Saldo CSV format

_Derived from a real export (10 049 rows, 4 887 transactions, Jun 2024 – Oct 2026) analysed on
2026-10-21. The real file is in git-ignored `samples/private/saldo_export.csv` — never commit it.
Examples below are synthetic._

## File

- UTF-8, comma-separated, every field double-quoted, header row.
- Columns: `Transaction ID, Transaction Date, Description, Parent account, Account,
  Account Type, Archived, Journal Type, Amount, Currency, Tags, Accrual Month, Notes`.
  (The owner's description listed `Account` twice; the second column is `Account Type`.)
- **Double-entry journal:** one transaction = 2–3 rows (legs) sharing `Transaction ID`.
  `Journal Type` is `DEBIT` or `CREDIT`; `Amount` is always positive — direction comes from the
  journal type. Description is identical across legs.
- `Transaction Date`: local time, no zone, three shapes: `2024-06-01T12:04:15`,
  `2025-02-27T12:27:24.835`, `2025-08-12T07:12`.
- `Accrual Month`: a full date (`2024-06-01`), equal to the transaction's date in every row —
  ignore.
- `Parent account`: always empty in the sample — ignore (handle if present: treat as group).
- `Archived`: `1` = the leg's account is archived in Saldo → create the Abacus account archived.
- `Tags`: free text, one tag per row at most in the sample; used for trips/projects → optional
  events (`R-IMP-SALDO-4`).
- `Notes`: free text → Abacus note.
- `Transaction ID`: numeric, unique per transaction → fingerprint `saldo:<id>`.

## Account types

| `Account Type` | Meaning | Abacus |
|----------------|---------|--------|
| `BANK_ACCOUNTS` | bank account/card | account, kind bank/card |
| `CASH` | cash wallet | account, kind cash |
| `OTHER_ASSETS` | e.g. broker account | account, kind investment |
| `LIABILITIES` | debts with people / credit | account, kind debt (liability) |
| `EXPENSES` | expense category (`Account` = category name) | expense category |
| `INCOME` | income category | income category |
| `EQUITY` | "Initial balance" | opening balance of the other leg's account |
| `MONEY_ON_THE_WAY` | in-transit clearing account for transfers | not an account — see pairing |

An Abacus account is identified by (`Account`, `Currency`): the same Saldo name can exist in two
currencies. Account currencies in the sample: UAH, PLN, EUR, USD only.

## Leg patterns → Abacus transaction

"Asset" below = BANK_ACCOUNTS, CASH, OTHER_ASSETS or LIABILITIES.

| Legs (sorted) | Share | Abacus |
|---------------|-------|--------|
| CREDIT asset + DEBIT EXPENSES | ~41 % | expense from asset |
| … with 2 DEBIT EXPENSES | rare | expense + attached record (split) |
| CREDIT asset + DEBIT asset | ~3 % | transfer (cross-currency when currencies differ) |
| CREDIT asset + DEBIT asset + DEBIT EXPENSES | ~3 % | transfer + attached fee |
| CREDIT INCOME + DEBIT asset | ~2 % | income to asset |
| DEBIT asset + CREDIT EXPENSES | <1 % | refund (`R-TX-4`) |
| CREDIT asset + DEBIT INCOME | <1 % | income reversal |
| CREDIT EQUITY + DEBIT asset | <1 % | opening balance |
| CREDIT asset + DEBIT MONEY_ON_THE_WAY | ~23 % | outgoing transfer half |
| CREDIT MONEY_ON_THE_WAY + DEBIT asset | ~23 % | incoming transfer half |
| … + DEBIT EXPENSES with a MOTW leg | rare | transfer half + attached fee |

Rules:
- **Currency mismatch inside an expense:** the asset leg is in the account currency and the
  expense leg may be in the merchant's currency (incl. HUF, CHF). Use the asset leg as the amount;
  store the expense leg as the original amount (`R-CUR-4`). With several expense legs, split the
  asset amount pro rata.
- **Unbalanced single-currency transactions** (11 in the sample, e.g. asset 100.00 vs expense
  98.85): the asset leg is the truth; flag a warning in the preview.

## Transfer pairing (`R-IMP-SALDO-2`)

Saldo stores most transfers as two independent transactions, each booked against a
`MONEY_ON_THE_WAY` (MOTW) leg. The MOTW leg's `Account` usually names the counterpart account, but
not reliably (a generic "Money on the way" also appears), so pairing must not depend on it.

Pair an outgoing half (DEBIT MOTW) with an incoming half (CREDIT MOTW) when:
1. MOTW amount **and** currency are equal,
2. the two asset accounts differ,
3. dates are ≤ 3 days apart — choose the closest; ties → earliest.

Sample result: 961 pairs from ~1 100 halves per side (943 same-day). The rest go to *needs
review*, where the user can pair manually, turn a half into an expense/income (e.g. money sent to
another person), or skip. The two halves' Saldo IDs both become fingerprints of the one transfer.

## Synthetic example

```csv
"Transaction ID","Transaction Date","Description","Parent account","Account","Account Type","Archived","Journal Type","Amount","Currency","Tags","Accrual Month","Notes"
"1001","2025-03-01T10:00:00","Initial balance","","Bank UAH","BANK_ACCOUNTS","0","DEBIT","1000.00","UAH","","2025-03-01",""
"1001","2025-03-01T10:00:00","Initial balance","","Initial balance","EQUITY","0","CREDIT","1000.00","UAH","","2025-03-01",""
"1002","2025-03-02T12:30:00","CAFE","","Bank UAH","BANK_ACCOUNTS","0","CREDIT","440.00","UAH","Trip 2025","2025-03-02",""
"1002","2025-03-02T12:30:00","CAFE","","Eating out","EXPENSES","0","DEBIT","10.00","EUR","Trip 2025","2025-03-02",""
"1003","2025-03-03T09:00:00","Top up","","Bank USD","BANK_ACCOUNTS","0","CREDIT","20.50","USD","","2025-03-03",""
"1003","2025-03-03T09:00:00","Top up","","Wallet USD","BANK_ACCOUNTS","0","DEBIT","20.00","USD","","2025-03-03",""
"1003","2025-03-03T09:00:00","Top up","","Fees","EXPENSES","0","DEBIT","0.50","USD","","2025-03-03",""
"1004","2025-03-04T08:00:00","To EUR card","","Bank UAH","BANK_ACCOUNTS","0","CREDIT","440.00","UAH","","2025-03-04",""
"1004","2025-03-04T08:00:00","To EUR card","","Bank EUR","MONEY_ON_THE_WAY","0","DEBIT","10.00","EUR","","2025-03-04",""
"1005","2025-03-04T08:00:00","From UAH card","","Bank EUR","BANK_ACCOUNTS","0","DEBIT","10.00","EUR","","2025-03-04",""
"1005","2025-03-04T08:00:00","From UAH card","","Bank UAH","MONEY_ON_THE_WAY","0","CREDIT","10.00","EUR","","2025-03-04",""
```
1001 → opening balance · 1002 → expense 440 UAH, original 10 EUR · 1003 → transfer 20 USD + fee
0.50 · 1004 + 1005 → one transfer 440 UAH → 10 EUR.
