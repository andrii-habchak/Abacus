# Decisions

Settled decisions, newest last. Each: what, why, date. Re-opening one needs the owner.

| # | Date | Decision | Why |
|---|------|----------|-----|
| D1 | 2026-10-21 | Project name **Abacus**; repo `andrii-habchak/Abacus` | Owner's choice |
| D2 | 2026-10-21 | macOS app first, iOS second | Owner's choice |
| D3 | 2026-10-21 | Supported currencies: UAH, PLN, EUR, USD | Owner's currencies |
| D4 | 2026-10-21 | Same git identity and SSH alias as Vigil; no AI attribution or assistant names in commits, PRs, README, docs | Owner rule |
| D5 | 2026-10-21 | Swift 6 + SwiftUI, macOS 26 (iOS 26 later), xcodegen; core logic in a local Swift package `AbacusKit` shared by both apps | Testable with `swift test`, iOS reuses everything below the views |
| D6 | 2026-10-21 | Persistence: SQLite via GRDB + SQLiteData, behind a repository layer; schema CloudKit-safe (UUID keys, archive flags) | Reports need SUM/GROUP BY; UNIQUE for import dedupe; real migrations; sync path for v2 |
| D7 | 2026-10-21 | Money stored as Int64 minor units + currency code; `Decimal` for math, never `Double` | Exactness; all 4 currencies have 2 decimals |
| D8 | 2026-10-21 | FX: official NBU rates via Frankfurter v2 (`providers=NBU`), fallback NBU API; period aggregates use the rate of each tx date, net worth uses the latest rate | Keyless, covers UAH/PLN/EUR/USD with history; past months stay stable |
| D9 | 2026-10-21 | Agent guide lives in `AGENTS.md`; `CLAUDE.md` is a committed one-line import of it | Fresh worktrees get the guide automatically |
