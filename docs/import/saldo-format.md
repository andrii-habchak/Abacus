# Saldo CSV format

_Status: **unknown** — no public documentation found (2026-10-21). To be filled in from an
anonymised sample export (TA §9 Q2). `R-IMP-3` is blocked until then._

## Columns (as given by the owner)

Transaction ID · Transaction Date · Description · Parent account · Account · Account · Type ·
Archived · Journal Type · Amount · Currency · Tags · Accrual Month · Notes

Hypothesis (unverified): Saldo uses a double-entry model in which categories are accounts too.
The two `Account` columns would then be the debit/credit (from/to) pair, and `Parent account` the
group of one of them.

## Questions to answer from the sample

1. Which app exactly (developer, App Store link)?
2. Distinct values of `Journal Type` and of `Type`; how they map to expense / income / transfer.
3. Is a transfer one row or two? For a cross-currency transfer, where are the second amount and currency?
4. What do the two `Account` columns hold for an expense, an income and a transfer? Which is the source?
5. `Parent account`: category group, account group, or the parent of a split/fee row? How is a fee linked to its transaction (shared Transaction ID?)
6. Amount sign: is an expense negative? Is the amount always in the `Currency` column's currency?
7. Format and timezone of `Transaction Date`; format of `Accrual Month`; which one should reports use?
8. `Archived`: archived account/category or archived transaction? `Tags` separator?
9. Encoding (UTF-8 with Cyrillic?), delimiter, decimal separator, quoting.
10. Are opening balances exported as rows?

## Mapping rules

_To be written once the sample is analysed._
