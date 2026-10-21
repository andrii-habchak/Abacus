# Status

_Last updated: 2026-10-21 (orchestrator)_

## Now

**P0 Foundation** and **D1 Prototypes** done (all six screen groups approved, `docs/design/`).
**Wave 2 running**: lanes A5 Store, A3 Saldo parser, A2 FX, A4 PKO parser — one session and
branch each (table below). A1 Calculators is the filler for the first lane that finishes.

## Done

- Repo `andrii-habchak/Abacus`; agent guide `AGENTS.md`.
- Research (comparable apps, multi-currency, FX sources, persistence) → TA + D5–D8.
- Saldo and PKO exports analysed → `docs/import/`. Real files in git-ignored `samples/private/`.
- TA v1.2 (all questions closed; prototype-review changes), decisions D1–D20, `PLAN.md`.
- P0 Foundation (`docs/status/P0.md`).
- D1 Prototypes: all six groups approved; sources + decisions in `docs/design/`.

## Next

1. Review and merge Wave 2 branches as they finish; start A1 when a slot frees up.
2. Wave 3: A6 Import pipeline (after A5) and UI lanes B1–B3 on PreviewData.

## In flight

| WP | Lane / session | Branch | State |
|----|----------------|--------|-------|
| A5 Store | background agent (own worktree) | `wp/A5-store` | running since 2026-10-21 |
| A3 Saldo parser | background agent (own worktree) | `wp/A3-saldo` | running since 2026-10-21 |
| A2 FX | background agent (own worktree) | `wp/A2-fx` | running since 2026-10-21 |
| A4 PKO parser | background agent | `wp/A4-pko` | **merged** 2026-10-21 (79/79 real rows parse) |

## Contract-change requests (orchestrator queue)

- A4: currency minor-unit helper for any ISO code in `Money.swift` (A3 likely needs it too).
- A4 → A6: normalise `Account.iban` (no spaces, no `PL`) before comparing with `counterpartyIBAN`;
  ATM rows arrive as `.transfer` to external account "Cash", currency exchange as `.transferHalf`.
