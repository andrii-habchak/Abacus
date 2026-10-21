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
| D10 | 2026-10-21 | Owner answers Q1–Q13 recorded in `REQUIREMENTS.md` §9 (last 30 days, subcategories, category-allocated budget, archived accounts out of net worth, date+time, no tags) | Owner's choice |
| D11 | 2026-10-21 | Short-term spending contexts (trips, relocation) are **Events**: one optional event per transaction, orthogonal to categories | Replaces Saldo tags without breaking category reports |
| D12 | 2026-10-21 | Imports share one pipeline (parse → normalise → dedupe → preview → commit); exact dedupe via a UNIQUE source fingerprint, fuzzy cross-source dedupe flagged in the preview; undo per import batch | Overlapping exports and Saldo/PKO overlap must never double-count |
| D13 | 2026-10-21 | Real exports live in git-ignored `samples/private/`; tests use synthetic fixtures only | Personal financial data stays off GitHub |
| D14 | 2026-10-21 | FX updates both automatic (launch/daily/on demand) and manual overrides per date or from a date | Owner request |
| D15 | 2026-10-21 | TA v1.0 agreed: Q14–Q21 answered; refunds counted as income unless the setting is on; PKO holds imported as completed and upgraded on settlement | Owner's answers |
| D16 | 2026-10-21 | Execution: orchestrator owns `main` + shared contract files; each WP runs as its own session in a worktree branch; 3–4 lanes at once; progress in `docs/status/<WP>.md` | Parallel work without merge conflicts; resumable |
| D17 | 2026-10-21 | Owner granted standing permission to commit and push without asking | Owner's choice |
| D18 | 2026-10-21 | Entities are SQLiteData `@Table` structs in AbacusDomain (one model for store, calculators, views); transaction type named `Txn`; import fingerprints are the primary key of `importFingerprints` | Single source of truth; sync-safe uniqueness without UNIQUE constraints |
| D19 | 2026-10-21 | No CloudKit-incompatible FK actions: `ON DELETE` only CASCADE / SET NULL; "can't delete while used" rules live in repositories | SQLiteData SyncEngine supports only those actions |
| D20 | 2026-10-21 | Phone notifications unavailable: Remote Control is disabled by the owner's organization policy; desktop banners only | Org policy |
| D21 | 2026-10-21 | PKO rows dated by the purchase day (`Data waluty`); booking day kept in `Txn.bookedDay` (migration v2) | Owner (Q22): spending lands on the day it happened |
| D22 | 2026-10-21 | A refund line inside a transaction is an attached record of kind `.income` in an expense category (no extra flag) | Only 1 real case; avoids a schema change; calculators treat it like a transaction-level refund (R-SET-3) |
| D23 | 2026-10-21 | App sources are an xcodegen synced folder | Parallel UI lanes add files without touching the `.xcodeproj` |
