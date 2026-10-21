# Synthetic Saldo fixtures (WP A3)

Hand-written CSVs in the format of docs/import/saldo-format.md. Never real data.

- `spec-example.csv` — the synthetic example of the format doc, verbatim.
- `patterns.csv` — one transaction per leg pattern (IDs 2001–2030): expenses, splits (pro rata,
  mixed and several foreign currencies), refunds, income and its split and reversal, transfers
  (same/cross currency, fees in each currency, refund leg, to itself), opening balance of a
  liability, debt/investment/cash/archived accounts, one name in two currencies, tags and notes
  with quotes and line breaks, an unsupported pattern, a paired half with a fee, the three date
  shapes.
- `pairing.csv` — MONEY_ON_THE_WAY halves (IDs 3011–3091): a chain where closest-first fails,
  closest and tie rules, the 3-day window, same account, transit currency mismatch, a
  cross-currency pair, incoming before outgoing, an unbalanced half.
