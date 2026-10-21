# PKO BP CSV format ("Zestawienie operacji")

_Derived from a real one-month export of a PLN personal account (80 rows) analysed on 2026-10-21.
The real file is in git-ignored `samples/private/` — never commit it. Examples below are
synthetic. Exports of the owner's PKO USD/EUR/company accounts may add cases — re-check when
they are first imported._

## File

- **Windows-1250** encoding (not UTF-8), CRLF line endings, comma-separated, all fields quoted.
- 12 columns. Header: `Data operacji, Data waluty, Typ transakcji, Kwota, Waluta,
  Saldo po transakcji, Opis transakcji` + 5 unnamed columns.
- Columns 7–12 hold `Key: value` detail strings, in varying order and count per row.
- **No transaction id** and **no own account number** in the file → the user picks the target
  account (`R-IMP-PKO-1`).
- Rows are newest first.

| Column | Example | Notes |
|--------|---------|-------|
| Data operacji | `2026-01-14` | booking date; **empty** for pending rows |
| Data waluty | `2026-01-13` | value date (card payment date) |
| Typ transakcji | `Płatność kartą` | see types |
| Kwota | `-15.89`, `+120.00` | signed, dot decimal |
| Waluta | `PLN` | account currency |
| Saldo po transakcji | `+1150.37` | running balance; `W rozliczeniu` for pending |

## Transaction types seen

| Typ transakcji | Meaning | Abacus |
|----------------|---------|--------|
| Płatność kartą | card payment | expense (refund if positive) |
| Płatność web - kod mobilny | BLIK online payment | expense |
| Przelew z rachunku | outgoing transfer | expense, or transfer if the recipient account is an Abacus account |
| Przelew na konto | incoming transfer | income, or transfer |
| Przelew na telefon przychodz. zew. | BLIK phone transfer | expense/income by sign |
| Wypłata w bankomacie - kod mobilny | ATM withdrawal | transfer to a cash account (user picks once; remembered) |
| WYMIANA W KANTORZE - UZNANIE | in-bank currency exchange (credit side) | transfer from the PKO currency account (pair with its export) |
| Blokada | pending card hold | **skip** (`R-IMP-PKO-2`) |

Unknown types → *needs review*, sign decides expense/income.

## Detail keys (columns 7–12)

`Tytuł` (title), `Lokalizacja` (`Adres: … Miasto: … Kraj: …`), `Data wykonania operacji`,
`Oryginalna kwota operacji` (merchant amount + currency → original amount), `Numer karty`,
`Rachunek odbiorcy` / `Nazwa odbiorcy` (recipient account/name), `Rachunek nadawcy` /
`Nazwa nadawcy` / `Adres nadawcy` (sender), `Numer telefonu`, `Operacja`, `Numer referencyjny`,
`Referencje własne zleceniodawcy`, `Bankomat`.

Description = merchant (from `Lokalizacja` `Adres`) or counterparty name, else `Tytuł`.

## Fingerprint (`R-IMP-3`)

`pko:<abacus account id>:<Data operacji>:<Data waluty>:<Kwota>:<Saldo po transakcji>:<sha1 of
the joined detail columns>`. The running balance keeps two identical same-day purchases apart
(11 same-day/same-amount pairs in one month of data). A pending `Blokada` row is never imported,
so its later settled row cannot collide with it.

## Cross-source overlap

The owner's Saldo history already contains the PKO accounts. Importing PKO for a period Saldo
already covers produces no exact matches (different sources) → the fuzzy rule (`R-IMP-4`) flags
them as *possible duplicate* and skips them by default.

## Synthetic example (shown in UTF-8; the real file is Windows-1250)

```csv
"Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","",""
"","2026-01-15","Blokada","-24.90","PLN","W rozliczeniu","Tytuł: P000000000000000000001","Lokalizacja: Adres: TAXI APP Miasto: Warszawa Kraj: POLSKA","","","",""
"2026-01-14","2026-01-13","Płatność kartą","-15.89","PLN","+1150.37","Tytuł: 000000000000000000000002","Lokalizacja: Adres: GROCERY STORE Miasto: Warszawa Kraj: POLSKA","Data wykonania operacji: 2026-01-13","Oryginalna kwota operacji: 15.89 PLN","Numer karty: 000000******0000",""
"2026-01-10","2026-01-10","Przelew na konto","+120.00","PLN","+1166.26","Rachunek nadawcy: 00 0000 0000 0000 0000 0000 0000","Nazwa nadawcy: JAN KOWALSKI","Adres nadawcy: UL. PRZYKŁADOWA 1 WARSZAWA","Tytuł: ZWROT","",""
```
