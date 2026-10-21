# Abacus — execution plan (v1, macOS)

_Status: agreed baseline 2026-10-21, built on TA v1.0 (`REQUIREMENTS.md`)._
Tick a work package (WP) here only when it is merged to `main`.

## 1. Code layout (created in P0, then fixed)

```
Abacus/
├─ project.yml, Abacus.xcodeproj      xcodegen; macOS app target "Abacus"
├─ App/macOS/<Feature>/               SwiftUI views, one folder per screen group
├─ AbacusKit/                         local Swift package
│  ├─ Package.swift
│  ├─ Sources/
│  │  ├─ AbacusDomain/                entities, Money/Currency, protocols; Calc/ = pure calculators
│  │  ├─ AbacusStore/                 GRDB + SQLiteData schema, migrations, repositories, queries
│  │  ├─ AbacusFX/                    rate providers, cache logic, converter, refresher
│  │  ├─ AbacusImport/                Core/ (contracts), Saldo/, PKO/, Pipeline/, Dedupe/, Rules/
│  │  └─ AbacusFeatures/<Feature>/    platform-neutral view models + PreviewData (reused by iOS)
│  └─ Tests/<Module>Tests/ + Tests/Fixtures/   synthetic fixtures only
├─ docs/  (status/<WP>.md = per-package progress notes)
└─ samples/private/                   real exports, git-ignored, main checkout only
```

**Shared files** — changed only by the orchestrator (§4), never by a lane:
`Package.swift`, `project.yml`, `*.xcodeproj`, `AbacusStore/Migrations/**`, `AbacusDomain/Model/**`,
`AbacusDomain/Protocols/**`, `AbacusImport/Core/**`, `docs/STATUS.md`, `docs/PLAN.md`,
`docs/DECISIONS.md`, `AGENTS.md`. A lane that needs a change there writes a request in its
`docs/status/<WP>.md` and pauses that part; the orchestrator lands it on `main`; the lane rebases.

## 2. Phases and work packages

Size: S ≈ one sitting, M ≈ 2–3, L ≈ 4+.

### Phase 0 — Foundation (sequential, orchestrator) — gate for everything except D1
- [ ] **P0 Foundation** (L) — owns everything it creates.
  - xcodegen project, macOS app target, `AbacusKit` package with the 5 modules and their test
    targets; dependencies GRDB + SQLiteData pinned.
  - **Contracts:** all domain entities (§3 of the TA) with IDs; `Money`/`Currency`; repository
    protocols; `RateProvider`/`CurrencyConverter`; import contracts (`ImportParser`,
    `NormalizedRow`, `Fingerprint`, `ImportPreview`); schema v1 migration with every table
    (incl. `fingerprint` UNIQUE, import batches, rates, rules, events, budgets, settings).
  - `PreviewData` mock data set for UI lanes; fixture folders; a test tag `.realData` whose tests
    read `$ABACUS_SAMPLES` (default `samples/private/`) and skip when files are missing.
  - App launches to an empty sidebar window. GitHub Actions: build + `swift test` (as Vigil's CI).
  - Exact build/test commands written into `AGENTS.md`.
  - Done when: `swift test` and `xcodebuild … build` green locally and in CI.

### Phase D — Screen prototypes (parallel with P0 and Phase 1; owner in the loop)
- [ ] **D1 Prototypes** (M + review rounds) — owns `docs/design/**`.
  Interactive macOS-styled HTML prototypes, one per group, iterated until the owner approves:
  1. Shell + Dashboard · 2. Transaction list + filters · 3. Editor (3 types, attached records,
  event) · 4. Accounts / Categories / Budget / Events / Rules · 5. Import wizard (preview,
  mapping, needs review, history/undo) · 6. Rates + Settings.
  Each approved group is frozen to `docs/design/<group>.md` + PNG. **Gate:** the matching B-lane
  starts only after its group is approved.

### Phase 1 — Core logic (parallel lanes, after P0)
- [ ] **A1 Calculators** (M) — owns `AbacusDomain/Calc/**`, its tests.
  Transaction effects and balances incl. attached records and transfers (R-ACC-3, R-TX-5/6);
  net worth assets − liabilities, archived excluded (R-HOME-1, R-ACC-4); refunds by setting
  (R-TX-4, R-SET-3); budget status incl. unallocated, parent covers children, over/near limit
  (R-BUD-*, R-HOME-2); event totals (R-EVT-3); category tree roll-ups (R-CAT-2).
- [ ] **A2 FX** (M) — owns `AbacusFX/**`, its tests.
  Frankfurter v2 `providers=NBU` client + NBU fallback, lazy historical fetch, weekend/holiday
  fallback, manual overrides per date and from-date, converter (date rate vs latest), refresher
  (launch / daily / on demand), failure → last known rates (R-FX-*). Network stubbed in tests.
- [ ] **A3 Saldo parser** (L) — owns `AbacusImport/Saldo/**`, Saldo fixtures + tests.
  Per `docs/import/saldo-format.md`: grouping, leg-pattern table, MOTW transfer pairing, original
  amounts, splits pro rata, opening balances, archived accounts, tags as event candidates,
  unbalanced warnings → `NormalizedRow`s (R-IMP-SALDO-*). `.realData` test: the full export parses,
  pairing ≥ 950 transfers.
- [ ] **A4 PKO parser** (M) — owns `AbacusImport/PKO/**`, PKO fixtures + tests.
  Per `docs/import/pko-format.md`: CP1250, detail keys, types, holds as pending, fingerprints,
  own-IBAN → transfer candidates, ATM → cash, original amount (R-IMP-PKO-*).
- [ ] **A5 Store** (L) — owns `AbacusStore/**` except `Migrations/`, its tests.
  Repositories with archive/delete/reassign rules (R-ACC-4/5, R-CAT-3); list query with all
  filters, search, sort, totals (R-LIST-*); dashboard aggregation queries; import batch commit in
  one DB transaction + undo (R-IMP-6); fingerprint uniqueness; backup export/restore (R-SET-2);
  20k-transaction performance test (R-NF-2).
- [ ] **A6 Import pipeline** (L) — after A5 merged — owns `AbacusImport/{Pipeline,Dedupe,Rules}/**`.
  Format detection, exact + fuzzy dedupe, pending→settled upgrade, needs-review queue, mapping
  memory, categorisation rules learning/applying, preview model, commit via the store
  (R-IMP-1…8, R-IMP-PKO-2).

### Phase 2 — macOS UI (parallel lanes; each after its D1 group is approved)
Each lane first builds its views on `PreviewData` → screenshots to the owner (SwiftUI check,
TA §6) → then wires them to the real view models as Phase 1 packages land.
Each owns `App/macOS/<Feature>/**` and `AbacusFeatures/<Feature>/**`.
- [ ] **B1 Shell, settings, rates** (M) — sidebar, toolbar, display-currency state, settings
  (R-SET-*), rates screen and manual overrides (R-FX-2/5), backup UI.
- [ ] **B2 Dashboard** (M) — net worth, budget with per-category bars, donut with drill-down,
  month selector (R-HOME-*). Swift Charts.
- [ ] **B3 Transaction list** (M) — filters, search, sort, day grouping, nested attached records,
  totals (R-LIST-*).
- [ ] **B4 Editor** (M) — 3 types, attached records, refunds, original amount, event pre-select,
  category suggestion, shortcuts (R-EDIT-*, R-TX-*, R-EVT-2).
- [ ] **B5 Management** (L) — accounts (archive warning), categories tree, budget editor,
  events, rules (R-MGMT-*).
- [ ] **B6 Import wizard** (L) — file pick, preview counts, mapping, needs-review resolution,
  tags→events, commit, history + undo (R-IMP UI).

### Phase 3 — Integration and acceptance (sequential, orchestrator)
- [ ] **I1 End-to-end on real data** (locally, `samples/private/`):
  full Saldo import → every account balance equals Saldo's; PKO import → balance equals the PKO
  file's latest "Saldo po transakcji"; re-import both → 0 new; PKO over a Saldo-covered period →
  possible duplicates flagged; undo import restores the previous state; performance (R-NF-2).
- [ ] **I2 Release** — ad-hoc signed DMG from CI, README with screenshots, tag `v1.0.0`.

### Phase 4 — v2 (planned after v1)
iOS app on `AbacusFeatures`, iCloud sync via SQLiteData `SyncEngine` (needs the paid Apple
Developer Program), backlog items from TA §7.

## 3. Dependencies and waves

```
Wave 1   P0 ─────────────────┐         D1 (owner reviews, runs alongside waves 1–3)
Wave 2   A5   A3   A2   A4   (A1)       ← up to 4 at once; A1 is the filler when one finishes
Wave 3   A6   B1   B2   B3              ← B-lanes on PreviewData, need their D1 group approved
Wave 4   B4   B5   B6   + wiring of B1–B3 to real view models
Wave 5   I1 → I2
```

Hard dependencies: everything → P0 · A6 → A5 (+ A3/A4 for real parsers; can use fixtures-only
stubs before) · B-lane → its D1 group · B6 → A6 · wiring → the A-package it uses · I1 → all.

## 4. How the work is executed

- **Orchestrator** (the lead session): owns `main`, the shared files (§1), merging, and
  `docs/STATUS.md`. It starts lanes, reviews and merges them, and keeps the plan ticked.
- **One lane = one session = one git worktree = one branch** `wp/<id>-<slug>`, started from the
  current `main` with the brief "Implement WP <id> from `docs/PLAN.md`". The lane:
  1. reads `AGENTS.md`, its WP here, the TA sections it cites;
  2. writes progress, blockers and contract requests to `docs/status/<id>.md` (its own file —
     no merge conflicts);
  3. commits on its branch, keeps tests green, pushes the branch;
  4. ends with a short report: what is done, what is not, test results.
- **Merge:** the orchestrator checks the diff stays in the lane's owned paths, runs
  `swift test` + app build, rebases/merges into `main`, ticks the WP, updates `STATUS.md`, pushes.
  Lanes still running rebase onto `main` when they need what was merged.
- **Concurrency: 3–4 lanes at once.** More makes review/merge the bottleneck and raises the
  chance of contract drift, for little gain on a codebase this size.
- **Real data:** worktrees do not contain `samples/private/` — set
  `ABACUS_SAMPLES=/Users/andrii_habchak/IdeaProjects/pet-projects/Abacus/samples/private` to run
  `.realData` tests from a worktree. Never copy real data into fixtures.
- **Resuming:** a new session reads `AGENTS.md` → `STATUS.md` → the open WP's
  `docs/status/<id>.md` and continues from there.

## 5. Definition of done (every WP)

- Each requirement ID the WP covers has at least one test naming it; `swift test` green;
  app builds.
- No edits outside the WP's owned paths (contract changes went through the orchestrator).
- `docs/status/<id>.md` says done, with anything deferred listed.
- Commit messages per `AGENTS.md`; branch pushed.
