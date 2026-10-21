# Synthetic PKO fixtures (WP A4)

Hand-written CSVs in the format of docs/import/pko-format.md, saved as Windows-1250 with CRLF
line ends. Never real data: names, account numbers, references and amounts are invented.

- `all-types.csv` — one row per transaction type in the spec (hold, card payment in PLN and in
  EUR, card refund, BLIK web payment, outgoing / incoming / phone transfer, ATM withdrawal,
  currency exchange) plus an unknown type, and two identical same-day purchases that differ only
  in the running balance.
- `settled-later.csv` — a later export: the hold from `all-types.csv` settled as a card payment,
  plus one row that overlaps `all-types.csv` unchanged.

Edit them as UTF-8 and convert back, e.g. `iconv -f UTF-8 -t WINDOWS-1250`; keep the CRLF line
ends and the no-break spaces in the exchange title.
