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
│  └─ Tests/<Module>Tests/ (+ AbacusImportTests/Fixtures/{saldo,pko}: synthetic only), Tests/AbacusTestSupport/
├─ docs/  (status/<WP>.md = per-package progress notes)
└─ samples/private/                   real exports, git-ignored, main checkout only
```

**Shared files** — changed only by the orchestrator (§4), never by a lane:
`Package.swift`, `project.yml`, `*.xcodeproj`, `AbacusStore/Migrations/**`, `AbacusDomain/Model/**`,
`AbacusDomain/Protocols/**`, `AbacusImport/Core/**`, `AbacusFeatures/PreviewData/**`,
`Tests/AbacusTestSupport/**`, `.github/workflows/**`, `docs/STATUS.md`, `docs/PLAN.md`,
`docs/DECISIONS.md`, `AGENTS.md`. A lane that needs a change there writes a request in its
`docs/status/<WP>.md` and pauses that part; the orchestrator lands it on `main`; the lane rebases.

## 2. Phases and work packages

Size: S ≈ one sitting, M ≈ 2–3, L ≈ 4+.

### Phase 0 — Foundation (sequential, orchestrator) — gate for everything except D1
- [x] **P0 Foundation** (L) — done 2026-10-21 — owns everything it creates.
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
- [x] **D1 Prototypes** (M + review rounds) — all six groups approved 2026-10-21 — owns `docs/design/**`.
  Interactive macOS-styled HTML prototypes, one per group, iterated until the owner approves:
  1. Shell + Dashboard · 2. Transaction list + filters · 3. Editor (3 types, attached records,
  event) · 4. Accounts / Categories / Budget / Events / Rules · 5. Import wizard (preview,
  mapping, needs review, history/undo) · 6. Rates + Settings.
  Each approved group is frozen to `docs/design/<group>.md` + PNG. **Gate:** the matching B-lane
  starts only after its group is approved.

### Phase 1 — Core logic (parallel lanes, after P0)
- [x] **A1 Calculators** (M) — merged 2026-10-21 — owns `AbacusDomain/Calc/**`, its tests.
  Transaction effects and balances incl. attached records and transfers (R-ACC-3, R-TX-5/6);
  net worth assets − liabilities, archived excluded (R-HOME-1, R-ACC-4); refunds by setting
  (R-TX-4, R-SET-3); budget status incl. unallocated, parent covers children, over/near limit
  (R-BUD-*, R-HOME-2); event totals (R-EVT-3); category tree roll-ups (R-CAT-2).
- [x] **A2 FX** (M) — merged 2026-10-21 — owns `AbacusFX/**`, its tests.
  Frankfurter v2 `providers=NBU` client + NBU fallback, lazy historical fetch, weekend/holiday
  fallback, manual overrides per date and from-date, converter (date rate vs latest), refresher
  (launch / daily / on demand), failure → last known rates (R-FX-*). Network stubbed in tests.
- [x] **A3 Saldo parser** (L) — merged 2026-10-21 — owns `AbacusImport/Saldo/**`, Saldo fixtures + tests.
  Per `docs/import/saldo-format.md`: grouping, leg-pattern table, MOTW transfer pairing, original
  amounts, splits pro rata, opening balances, archived accounts, tags as event candidates,
  unbalanced warnings → `NormalizedRow`s (R-IMP-SALDO-*). `.realData` test: the full export parses,
  pairing ≥ 950 transfers.
- [x] **A4 PKO parser** (M) — merged 2026-10-21 — owns `AbacusImport/PKO/**`, PKO fixtures + tests.
  Per `docs/import/pko-format.md`: CP1250, detail keys, types, holds as pending, fingerprints,
  own-IBAN → transfer candidates, ATM → cash, original amount (R-IMP-PKO-*).
- [x] **A5 Store** (L) — merged 2026-10-21 — owns `AbacusStore/**` except `Migrations/`, its tests.
  Repositories with archive/delete/reassign rules (R-ACC-4/5, R-CAT-3); list query with all
  filters, search, sort, totals (R-LIST-*); dashboard aggregation queries; import batch commit in
  one DB transaction + undo (R-IMP-6); fingerprint uniqueness; backup export/restore (R-SET-2);
  20k-transaction performance test (R-NF-2).
- [x] **A6 Import pipeline** (L) — merged 2026-10-21 (incl. headless defaults) — after A5 merged — owns `AbacusImport/{Pipeline,Dedupe,Rules}/**`.
  Format detection, exact + fuzzy dedupe, pending→settled upgrade, needs-review queue, mapping
  memory, categorisation rules learning/applying, preview model, commit via the store
  (R-IMP-1…8, R-IMP-PKO-2).

### Phase 2 — macOS UI (parallel lanes; each after its D1 group is approved)
Each lane first builds its views on `PreviewData` → screenshots to the owner (SwiftUI check,
TA §6) → then wires them to the real view models as Phase 1 packages land.
Each owns `App/macOS/<Feature>/**` and `AbacusFeatures/<Feature>/**`.
- [x] **B1 Shell, settings, rates** (M) — merged 2026-10-21, wired to the live database (all sections but Import) — sidebar, toolbar, display-currency state, settings
  (R-SET-*), rates screen and manual overrides (R-FX-2/5), backup UI.
- [x] **B2 Dashboard** (M) — merged and wired to the live database 2026-10-21 — net worth, budget with per-category bars, donut with drill-down,
  month selector (R-HOME-*). Swift Charts.
- [x] **B3 Transaction list** (M) — merged and wired to the live database 2026-10-21 — filters, search, sort, day grouping, nested attached records,
  totals (R-LIST-*).
- [x] **B4 Editor** (M) — merged and wired to the live database 2026-10-21 — 3 types, attached records, refunds, original amount, event pre-select,
  category suggestion, shortcuts (R-EDIT-*, R-TX-*, R-EVT-2).
- [x] **B5 Management** (L) — merged and wired to the live database 2026-10-21 — accounts (archive warning), categories tree, budget editor,
  events, rules (R-MGMT-*).
- [x] **B6 Import wizard** (L) — merged and wired 2026-10-21 — file pick, preview counts, mapping, needs-review resolution,
  tags→events, commit, history + undo (R-IMP UI).

### Phase 3 — Integration and acceptance (sequential, orchestrator)
- [ ] **I1 End-to-end on real data** (locally, `samples/private/`):
  full Saldo import → every account balance equals Saldo's; PKO import → balance equals the PKO
  file's latest "Saldo po transakcji"; re-import both → 0 new; PKO over a Saldo-covered period →
  possible duplicates flagged; undo import restores the previous state; performance (R-NF-2).
- [x] **I2 Release** (2026-10-27, local DMG per D37) — ad-hoc signed DMG from CI, README with screenshots, tag `v1.0.0`.

### Phase 3b — Small items and release (2026-10-21)
- [x] **C1 List filters** (merged 2026-10-22) — uncategorised and import-batch filters through store, list, dashboard
  drill-down and import "Show transactions".
- [x] **C2 Settings, data, defaults** (merged 2026-10-22) — last backup date in the database, data folder Change…,
  default categories on first launch, editor fetches rates for old days.
- [x] **R1 Release prep** (merged 2026-10-22; DMG built and `v1.0.0` tagged 2026-10-27) — app icon, version 1.0.0, `scripts/build-dmg.sh`, README with
  sample-data screenshots, CHANGELOG. Orchestrator then builds the DMG and tags `v1.0.0`.
- [x] **C3 Import window height** (merged 2026-10-27) — the choose-file paragraph's vertical
  `fixedSize` set a 2,251 pt minimum window height; removed. DEBUG `-AbacusImportFile <csv>`.

### Phase 3c — Owner review of v1.0.0 (2026-10-27, TA v1.5, D42–D45)
- [x] **C4 Navigation** (merged 2026-10-27) — click-only donut drill-down, budget edit button,
  currency switch only on Dashboard/Transactions/Accounts/Events.
- [x] **C5 Colours** (merged 2026-10-27) — random + manual colours for categories, accounts, events; category-coloured
  transaction icons. Migration "v4: colours".
- [x] **C6 Budget currency** (merged 2026-10-27) — per-category limit currency, no separate total. Migration "v5".
- [x] **C7 Rules** (merged 2026-10-27) — Saldo-like conditions and category/transfer actions. Migration "v6: rules".
- [ ] **Release 1.1.0** — DMG built for owner testing; superseded by the 1.2.0 round below.

### Phase 3d — Owner review of 1.1.0 (2026-10-27, TA v1.6, D46–D50)
Wave 1 (parallel):
- [x] **C8 Budget** (merged 2026-10-27) — widget bug (wrong limit currency), total + currency + unallocated (D46),
  switcher on Budget page, red trash, Save bottom-right.
- [x] **C9 Rules** (merged 2026-10-27; migration v8) — apply-to-existing bug, rollback, amount-only condition, category filter,
  page search.
- [x] **C10 Categories** (merged 2026-10-27; migration v9) — built-in Uncategorised (D47), same colour everywhere, A–Z pickers,
  sort selector, search, drag-to-nest, New transaction preselects the category.
- [x] **C11 Transactions, events, shell** (merged 2026-10-27) — page search on Transactions/Events, event inspector
  layout + read-only archived event, type filter layout, Save bottom-right in event inspector.
Wave 2:
- [x] **C12 Accounts** (merged 2026-10-27; migration v11) — account groups (D48), drag/sort/search/currency filter, grouped pickers,
  net worth hierarchy.
- [x] **C13 Dashboard widgets** (merged 2026-10-27) — income donut, income vs expenses, drag-reorder widgets.
- [x] **C14 Debts** (merged 2026-10-27; migration v10; widget scroll fix pending) — `R-DEBT` (TA v1.7, D51).
- [ ] **Release 1.2.0** — DMG built for owner testing; superseded by 1.2.1 below.

### Phase 3e — Stability and owner review of 1.2.0 (2026-10-27, D54–D56)
- [x] **S1 Stability and performance** (merged 2026-10-27) — crashes (binding force-unwrap, Escape), hangs, reload storms, timing on owner-size data.
- [x] **S2 Accounts and categories lists** (merged 2026-10-27) — native outline drag and drop, sheet editors, split New account button, new-tx prefill for accounts.
- [x] **S3 Budget and rules polish** (merged 2026-10-27) — Save button states, remove the rules tester row.
- [ ] **Release 1.2.1**.

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
