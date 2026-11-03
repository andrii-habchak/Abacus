# N6 — Reconciliation: spec (proposed TA text)

State: spec for owner review (no code, no migration written)   ·   Branch: wp/N6-spec   ·   Updated: 2026-11-03

Roadmap item N6 (`docs/ROADMAP.md` §5), approved by the owner 2026-11-03 (D71) with a spec step first.
This note is the proposed TA text with new `R-CLR-…` IDs; the orchestrator folds it into
`docs/REQUIREMENTS.md` (new §4.7 "Reconciliation", change-log row, `R-TX-2` gets one field, backlog
line "reconciliation" removed) after the owner approves. The prototype is
`docs/design/N6-reconcile.dc.html` (synthetic data; Transactions with the cleared column, Accounts →
Reconcile, Import preview with the new checks). Examples below are synthetic.

Facts used from the code (checked 2026-11-03): migrations end at v17 (`AbacusStore/Migrations/Schema.swift`;
v18 is reserved for N5, v19 for this item); the fuzzy cross-source match is `FuzzyDuplicate`
(`AbacusImport/Dedupe/Matching.swift`: same account and amount, other source or hand-typed, ± 3 days,
similar description, description waived on the same day or against a transfer); a PKO hold settles via
`PendingSettlement` (same file, value day ± 3, merchant, amount within 5 %); `Txn.isPendingAtBank`,
`Txn.bookedDay`, `isBalanceCorrection`, `isEstimatedTransferAmount`, `importTxnSnapshots` (undo of
absorbed/completed rows), `importFingerprints` (id, txnID, batchID), `ImportBatch.accountID`,
`TxnSource` = manual / saldo / pko.

## 1. Concepts

- **Cleared** = "a bank (or the owner's former Saldo book) has confirmed this row". A bank row cannot
  disappear, so a cleared row is the part of the history the owner trusts.
- **Clearing is bookkeeping only.** It never changes balances, net worth, budgets, reports or exports.
- A **statement balance** is the closing balance printed by the bank for a statement date; the
  **cleared balance** is the account's opening balance plus the effect of cleared rows booked on or
  before that date. When the two are equal the account agrees with the bank.
- A transfer touches two accounts, so cleared is kept **per side**.

## 2. Requirements

### 2.1 Cleared flag — `R-CLR-1`, `R-CLR-2`, `R-CLR-3`

- `R-CLR-1` **Data.** A transaction has `isCleared` (the side on `accountID`) and `isToCleared`
  (transfers only: the side on `toAccountID`; always false otherwise). New table `reconciliations`
  (`R-CLR-5`). Shown in `R-TX-2` as "cleared". Migration **v19** (reserved), following the file's
  header rules and D18/D19:
  - `txns.isCleared INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0` and
    `txns.isToCleared INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0` (the v14/v16 pattern; each
    added only when the column is missing, so the migration can run again);
  - `CREATE TABLE IF NOT EXISTS "reconciliations"` (`id TEXT PRIMARY KEY`, `accountID TEXT NOT NULL
    REFERENCES accounts(id) ON DELETE CASCADE`, `statementDay TEXT NOT NULL`, `closingMinor INTEGER
    NOT NULL`, `correctionMinor INTEGER NOT NULL DEFAULT 0`, `finishedAt TEXT NOT NULL`) STRICT, one
    index on `accountID`. No UNIQUE, only CASCADE, plain additive columns: CloudKit-safe;
  - an index on `txns(isCleared)` is **not** added (the Reconcile query filters by account and day first).
  - Domain: `Txn.isCleared`, `Txn.isToCleared` (default false in the initialiser), a `Reconciliation`
    `@Table` struct; both `Txn` fields join the `Codable` snapshot used by `importTxnSnapshots`, with
    `decodeIfPresent` so snapshots written before v19 still decode (as uncleared).
- `R-CLR-2` **Backfill** (inside v19, one `UPDATE` per rule, in this order; a later rule never
  un-clears what an earlier one set):
  1. `isPendingAtBank = 1` → both flags 0 (a hold is not booked).
  2. `source IN ('pko','saldo')` and not pending: a non-transfer gets `isCleared = 1`; a Saldo
     transfer gets both sides; a PKO transfer gets each side whose account is the target
     (`ImportBatch.accountID`) of a batch that holds one of the transaction's fingerprints (if no
     batch names an account, the from-side). A PKO transfer whose other statement was never imported
     keeps that side uncleared.
  3. `source = 'manual'` with at least one `importFingerprints` row (it was linked to a bank row, or
     absorbed as a counterpart): the side(s) selected by rule 2's per-side test are cleared (Saldo-fingerprinted rows: both sides).
  4. `isBalanceCorrection = 1` → `isCleared = 1` (it restates the bank balance, D34, `R-ACC-4`).
  5. Everything else (hand-typed rows, debt legs without a fingerprint, duplicates) stays 0.
  `isEstimatedTransferAmount = 1` transfers keep the estimated side uncleared until a later import
  completes them (`R-CLR-7`).
  Because Saldo history is the bulk of the data, the first launch of 1.7 will show thousands of cleared
  rows and a handful of uncleared ones (hand-typed since, holds, debt legs): that is expected, and
  the pre-migration snapshot of N1 covers a rollback.
- `R-CLR-3` **Semantics.**
  - An attached record (`R-TX-6`) has no flag of its own: it follows its parent. The effect on an
    account is the parent's whole effect (main ± attached), cleared or not as one.
  - Amounts are in the account currency: the charged amount for a foreign purchase (`R-CUR-4`), the
    sent amount on the from-side and the received amount (`toAmountMinor`) on the to-side of a
    transfer. The statement is in the account currency, so no conversion happens in a reconciliation.
  - A refund or reversal counts with the sign of its flow (money in), like a balance.
  - Editing a cleared row's amount, date, account or type asks "This row is confirmed by the bank.
    Changing it will make the reconciled balance differ" and keeps the flag (the owner may be fixing
    a typo). Duplicate and "Convert to debt record" produce uncleared rows. Moving an import batch to
    another account (C48) keeps the flags and moves them with the rows.
  - A row's place in time for reconciliation is its **statement day** = `bookedDay` when present, else
    its day. PKO statements are by booking day while rows are dated by purchase day (`R-IMP-PKO-4`,
    1–3 days apart); using the purchase day would give false differences around the statement date.
    Saldo and hand-typed rows have no booking day and use their own day.

### 2.2 List and editor — `R-CLR-4`

- `R-CLR-4`
  - Transactions list: a narrow column left of the description with a **cleared indicator**: filled
    green check = cleared, hollow circle = uncleared, clock = pending hold, half-filled = transfer
    cleared on one side (the tooltip names which). The row shows the side of the account in view; with
    several accounts selected it shows "cleared" only when every side shown is cleared.
  - Filter group **All / Cleared / Uncleared** in the filter bar (combinable; "Clear filters" resets it).
  - **Mark cleared / Mark uncleared** for the selected rows (button and context menu), and a "Cleared"
    checkbox in the editor ("Confirmed by the bank"). Pending holds cannot be marked cleared. For a
    transfer the editor shows one checkbox per side.
  - Account window (the pop-up that edits an account): "Balance 3,481.25 · cleared 3,569.55", "Reconciled to 21 Oct 2026 · 3,569.55"
    (or "Never reconciled") and a **Reconcile** button; the Transactions toolbar has the same button
    when exactly one account is filtered.
  - Footer totals gain "Uncleared" for a single account (balance minus cleared balance).
  - **Mark settled** (button and context menu) on a selected pending hold: the payment went through, so
    it stops being pending (`isPendingAtBank = 0`) and stays uncleared until a bank row confirms it.
    It is a separate action from editing the row; it also works in bulk on several selected holds.
  - Clicking the indicator does **not** toggle it (too easy to hit while scrolling); see Q9.

### 2.3 Reconcile mode — `R-CLR-5`, `R-CLR-6`

- `R-CLR-5` **Reconcile (bank, card, savings, investment and liability accounts).**
  *What it is for.* The owner compares Abacus with the bank's statement and settles every
  difference, so that the cleared part of the account is known to be right. Two numbers come from the
  bank statement and are typed in once per run:
  - **Statement date** = the last day the statement covers (the "balance as of" date printed on the
    PDF or shown in the bank's app). Abacus only looks at rows booked up to that day; later rows are
    shown dimmed and are not part of the check.
  - **Closing balance** = the balance the bank shows at the end of that day, in the account's
    currency. Abacus compares it with its **cleared balance** (opening balance + cleared rows up to
    that day). The two must agree.
  *How it is opened (entry points).* (1) Accounts → open the account (its edit window) → the **Reconcile** button next to the balance, which
  also shows the cleared balance and the last reconciliation; (2) Transactions toolbar → **Reconcile** when exactly one account
  is filtered; (3) the import's Done step: "Reconcile <account>" with the date and closing balance
  already filled from the file's last running balance (PKO); (4) a soft **"Not reconciled"** badge on
  the account row and inspector when the account has cleared rows booked after the last reconciliation
  (or was never reconciled). The badge is a hint only: no pop-up, no notification, nothing blocks.
  Besides a new import, then, reconciliation appears when the owner opens it (1, 2) or sees the badge
  (4).
  *The request.* Opening Reconcile first shows a short setup step (no data is changed): an
  explanation in two lines, the two fields with the help above, a note where the values came from
  ("Filled from the file you just imported" or "Last reconciled 21 Oct 2026"), and **Start
  reconciling**. The statement date defaults to the last reconciliation's date or, failing that, the
  account's last booked day; the closing balance is typed as the account's balance appears in
  Abacus (a credit card in debt is negative; the hint says so, Q12). The working screen then shows
  the two values as an editable header ("Change").
  *Working screen.*
  - Three figures: statement balance, **cleared balance**, **difference** = statement − cleared (red
    until 0, green at 0, with a one-line reason by sign: lower → "a payment is missing from the cleared
    rows, or a row is ticked that the bank did not book"; higher → "income or a refund is missing").
  - List: **To check** (uncleared rows with statement day ≤ the date, newest first) with a checkbox
    each and "Tick all"; **Already cleared** (collapsed; read-only unless the owner confirms
    unticking a bank-file row); **After the statement date** (dimmed). Pending holds are listed
    unticked and disabled, labelled "Pending — not on a statement", with the row action **Mark
    settled** (`R-CLR-4`). Holds older than the stale threshold (`R-CLR-8`) carry "Pending for N
    days".
  - **Ways to make the difference zero** (a help box under the figures names them; none is forced):
    1. **Tick** a row that is on the statement and in Abacus but not yet cleared (the common case:
       a hand-typed payment the bank has booked).
    2. **Add transaction** for a payment the statement has and Abacus does not: a small form (day,
       description, amount typed with a sign: "-12.50" or no sign = money out, "+5" = money in; category; the type follows the sign; a transfer is added in
       the normal editor) creates the row **already cleared** (it is on the statement) and it counts
       at once. The owner can add several during one run.
    3. **Edit** an uncleared row whose amount or day differs from the statement (inline amount and
       day), then tick it.
    4. **Delete** an uncleared hand-typed row the bank never booked (confirmation; a bank-file row is
       never deleted here).
    5. **Mark settled / delete a pending hold** that is not on the statement (the hold is not part of
       the cleared balance either way).
    6. **Balance correction** as the last resort ("Add correction X and finish", below).
  - All staged changes (ticks, added rows, edits, deletions) live in memory and change the figures
    live; **Cancel** discards them, leaving the screen with staged changes asks first, and **Finish**
    writes them in one database transaction.
  - **Finish reconciliation** is enabled only at difference 0: it sets the ticked sides cleared,
    applies the staged additions, edits and deletions, stores a `reconciliations` row, and says
    "Reconciled … N rows marked cleared". With a non-zero difference the owner may instead "Add
    correction X and finish": one `Balance correction` row (`isBalanceCorrection`, cleared, dated the
    statement day, same mechanism as D34, not income or expense).
  - **Drift.** Every time the screen opens, the last reconciliation is recomputed (cleared balance at
    its `statementDay` now vs its `closingMinor`). If they differ a red note says "The last
    reconciliation no longer adds up: … A cleared row was edited or removed since." Nothing is locked.

- `R-CLR-6` **Cash accounts (kind `cash`).** There is no bank, so the statement is a **counted
  amount** ("Count date", "Counted cash"). The compared figure is the **whole balance at the count
  date** (every row, cleared or not, with day ≤ the date), because every cash row is hand-typed; "Tick
  all up to the date" is the primary action, and Finish marks all of them cleared. A difference is
  closed with a correction row as above. Rows dated after the count date are shown dimmed.

### 2.4 Clearing at import — `R-CLR-7`

- `R-CLR-7`
  - **Bank rows.** A row created from a PKO file is cleared unless it is a hold (`Blokada`), which is
    created pending and uncleared (`R-IMP-PKO-2`). **Every row created from a Saldo file is cleared**
    (the owner is migrating from Saldo; an import never deletes anything). Transfers are cleared on the
    side(s) whose account the file belongs to: both sides for Saldo, the target account's side for PKO
    (the other side only when it is also seen in a file, below).
  - **Settled hold.** A hold upgraded by a settled row (`PendingSettlement`, `R-IMP-PKO-2`) becomes
    cleared and not pending, and gets the booking day.
  - **Hand-typed row confirmed by a bank row.** A row with no exact fingerprint that `FuzzyDuplicate`
    matches to an existing transaction (the same rule as `R-IMP-4`: same account, amount, other source
    or hand-typed, ± 3 days, similar description or same day/transfer) where the existing one is
    **hand-typed and uncleared**: the preview's default action becomes **Link** (not Skip), labelled
    "Confirms your hand-typed row and marks it cleared". Linking (`R-IMP-4`) stores the fingerprint on
    the existing row, sets it cleared and fills its `bookedDay` if empty; its amount, category, note and
    other fields stay as typed. Skip and Import anyway remain available; Skip leaves it uncleared.
    A possible duplicate whose existing row is already cleared (a Saldo row) keeps the default Skip.
  - **Absorbed counterpart / completed estimate (C38).** When an import turns an existing
    transaction into one side of a transfer, or completes an estimated transfer amount, the
    side that belongs to the file's account becomes cleared; the estimate flag clears as today.
  - **Undo of the batch.** Every row that import *changed* (cleared flag set, hold settled or
    deleted, link added) is first saved in `importTxnSnapshots` with its previous flags, so Undo
    restores it uncleared/pending. Rows the batch *created* are deleted as before.
    (Today a settled hold is not tagged with the batch, so its undo is a known gap; this item closes it
    for the cleared flag by snapshotting; settling itself stays as is.)
  - **Headless** (`abacus-import`): same pipeline, same results, no extra options. Defaults:
    possible duplicates against hand-typed uncleared rows are linked (as above), stale holds are kept
    (never deleted without the owner), balance gaps are printed as warnings. `--dry-run` prints the
    counts without writing.
  - The wizard's Done step and the import history line include the clearing counts (e.g. "2 cleared · 1
    hand-typed row confirmed · 1 hold settled").

### 2.5 Stale pending holds — `R-CLR-8`

PKO holds (`Blokada`) vanish from later exports; today one that is released and never settles stays
pending forever and the owner must find and delete it.

- `R-CLR-8` At preview time, for a PKO file, an existing transaction is a **stale hold** when all of:
  - it is `isPendingAtBank`, `source = 'pko'`, on the target account;
  - its value day (the transaction's day) is **at least 5 days before the file's last booked day**
    (`staleHoldDays = 5`; settled rows are booked 1–3 days after the purchase and matched within ± 3,
    so by day 5 the settled row would be in a file booked that far);
  - the file **covers** it: value day ≥ the file's first booked day − 3 (the same ± 3 window as
    `PendingSettlement`); an older hold is out of this file's reach and is left to the Reconcile list;
  - no row of the file settled it (`PendingSettlement` found no match), no row links to it
    (`FuzzyDuplicate`), and the file does not contain the same hold again (its fingerprint is not among
    the file's rows).
  *Where it appears.* The import preview's summary cards work as the tabs: All rows, New, Already
  imported, Possible duplicates, Settle pending, **Needs review**. Choosing a card shows exactly the
  rows of that card (All rows shows all, Needs review shows only what needs a decision). **Needs
  review** has its own sub-tabs: **All**, **Decisions** (the current cards), **Pending payments (N)**
  and **Balance gaps (N)** (`R-CLR-9`); each sub-tab lists only its items, "All" lists the three
  groups one after another. The card counts everything open. The former "Accounts & categories" tab
  is not shown for a PKO file: a PKO file belongs to one account, picked in "Import into", so there is
  nothing to map; it stays for Saldo files (dozens of accounts and categories) and appears for a PKO
  file only when it has counterparties to map. Each stale hold is listed as **"Pending payment not in
  the bank file"** with merchant, amount, value day, the file's last booked day and the distance in
  days, and one decision:
  - **Keep pending** — no change; raised again at the next import while it still qualifies (Q4);
  - **Mark settled** — the payment did go through: the hold stops being pending (amount, day and
    category stay) and stays **uncleared**, because no bank row confirms it; Reconcile will show it
    under "To check" until a statement does;
  - **Delete** — the transaction is removed when the import is committed;
  - **Edit** — inline amount, purchase day and a "Still pending" checkbox; saving keeps it
    **uncleared** (the file does not show it).
  *Bulk actions.* Selection works like Finder: click selects one item, **⌘ click** adds or removes one,
  **⇧ click** selects everything from the last clicked item to this one; each item also has a checkbox
  and there is "Select all" (the same on the Transactions list). A bulk bar applies **Keep pending**, **Mark
  settled** or **Delete** to the selected items (Edit is per item). The bulk bar also exists on
  Transactions for pending rows (`R-CLR-4`).
  - Decisions start **undecided**; Import is disabled until every stale hold has one ("N pending
    payments not in the file still need a decision"); **Keep all** decides them in one click. This
    follows D38 (only fully decided previews commit).
  - All decisions commit with the batch in one database transaction (`R-IMP-6`). Mark settled, Delete
    and Edit are snapshotted in `importTxnSnapshots` (the snapshot stores the whole transaction; Undo
    re-inserts a deleted one and restores an edited or settled one), so **Undo import** brings them
    back.
  - **How the owner learns whether this happens at all:** the "Pending payments" sub-tab and card
    show their count on every PKO import, including 0 ("none found"); the import history line records
    "N stale holds: a kept, b settled, c deleted, d edited"; `abacus-import` prints the count. A few
    months of history answers the question without a separate report.
  - A held transaction on a **different** account than the target, or from Saldo, is never raised.

### 2.6 Balance continuity — `R-CLR-9`

PKO's `Saldo po transakcji` is the balance after each booked row; Saldo files have none (no check).

- `R-CLR-9` For a PKO file's booked rows (holds excluded; they have no balance), after parsing and
  before the preview is built:
  1. **Chain check.** Row *j* follows row *i* when `balanceAfter_i + amount_j = balanceAfter_j`
     (signed amounts). Rows are not strictly newest-first and a day holds several rows with equal
     keys (`pko-format.md`), so the check does not trust file order: it takes the rows of one booking
     day as a set, finds the order that chains from the previous day's last balance (rows match by
     `balanceAfter − amount` against the available balances, multiset-style so equal balances do not
     confuse it), and moves on. Exactly one start (the oldest row) and one end (the newest) is healthy.
  2. **Gap.** When the rows of a day cannot be chained from the previous day's closing balance, the
     tool reports a **balance gap** between the two booking days: the missing net amount =
     (next row's starting balance) − (previous closing balance), shown signed. Rows adding up to that
     amount are not in the file (e.g. an export that skipped a day, or rows the bank booked
     out of order beyond the file's window). Zero amounts, a repeated balance and reversed pairs
     (+x then −x) are chained like any other row.
  3. **File start vs the account.** The oldest row's starting balance (`balanceAfter − amount`) is
     compared with the account's cleared balance at the end of the day before the file's first booked
     day, when the account has cleared rows before it. A difference is shown as "The file starts at X
     but <account> has Y (difference D)". It is also the hint for a wrong target account (C41 §5):
     a match is shown quietly ("File start matches PKO Personal"). Skipped on a first import.
  4. **File end** (no warning): the newest row's balance and booked day are kept for the "Reconcile
     prefilled" offer (`R-CLR-5`).
  - *Where and what can be done.* The **Balance gaps (N)** sub-tab of Needs review lists each gap
    (oldest first) with a small table of the two rows around it (amount, balance after, "starts
    from"), the missing amount and a one-line advice. Each of the two rows has an action:
    **Leave** (default: it is imported as the file says) or **Remove** (the row is not imported, e.g.
    to export a corrected period and import again; it counts as skipped). "Leave all" is one click.
    A gap is a warning: it never blocks the import and needs no decision; the warning and the choice
    are kept on the import record (history shows "1 balance gap, 0 rows removed").
  - Threshold: a gap of 0.00 is not a gap; no tolerance (money is exact, `R-CUR-2`). A foreign-currency
    PKO account is checked in its own currency; the file is single-currency, so no conversion.

### 2.7 Edge cases (for all of the above)

| Case | Rule |
|------|------|
| Multi-currency | A reconciliation is in one account currency; transfers use the account's own side amount; charged amount for foreign purchases. No FX at all. |
| Refund / reversal | Counted by flow, like the balance. Linked refunds (`refundOfID`) are independent rows with their own flag. |
| Absorbed transfer (C38) | The absorbed counterpart's flag for the file's side is set by the import and restored by its snapshot on undo. |
| Estimated transfer amount (D64) | The estimated side stays uncleared until a later import completes it; the Reconcile screen shows it under "To check" with an "estimate" badge, tickable only after a confirmation. |
| Undo import | Created rows go; changed rows (cleared, linked, held, deleted, edited) are restored from snapshots (`R-CLR-7`). Undoing an earlier batch after a later one absorbed a row stays the known open item (C41). |
| Backup / restore (R-SET-2) | Flags and `reconciliations` are in the database, so backup and restore carry them. A backup from before v19 is migrated on restore (`prepare`), so the backfill rules apply to it. N1's pre-migration snapshot is taken before v19. |
| Headless import | `R-CLR-7` last bullet. |
| Moved batch (C48) | Flags travel with the rows; the `reconciliations` of both accounts will show drift until redone, which is correct. |
| Archived / deleted accounts | An archived account keeps its reconciliations; deleting an account (only with no transactions, `R-ACC-5`) cascades them. |
| Account with no opening date / opening balance changed | The opening balance is part of every cleared balance; changing it shows as drift. |
| Hand-typed row later than the statement date | In "After the statement date", not part of the check. |
| Two hand-typed rows match one bank row | One match per existing row (D31); the second stays uncleared, shown in Reconcile. |
| Saldo-then-PKO overlap | Saldo rows are already cleared; the PKO row is a possible duplicate with default Skip (unchanged). |

## 3. Tests (ideas per ID; synthetic fixtures only; Swift Testing, each references its ID, `R-NF-5`)

- `R-CLR-1`: migration v19 on a v18 database adds both columns with default 0 and the table; running
  it twice is a no-op; existing rows stay readable; `importTxnSnapshots` JSON without the new keys
  decodes uncleared; a fresh database equals a migrated one (schema dump).
- `R-CLR-2`: one fixture row per class (Saldo expense; Saldo transfer; PKO expense; PKO transfer with
  one statement imported, with both; PKO hold; manual; manual with a `pko:` fingerprint; balance
  correction; estimated transfer; debt leg) → expected flags; a backup file made at v18 restored then
  migrated gives the same.
- `R-CLR-3`: balances, net worth, budget and report totals identical before/after clearing; attached
  records follow the parent; statement-day basis (a PKO row purchased 05.10, booked 06.10 is outside
  a 05.10 statement); cross-currency transfer sides use their own amounts; refund sign.
- `R-CLR-4`: list filter over cleared/uncleared/combined with account and category filters; indicator
  state per row kind (pure view-model function); Mark cleared on a hold is refused; transfer
  half-state; editor save keeps the flag; the warning appears for amount/date edits of a cleared row.
- `R-CLR-5`: entry points open the setup step prefilled (import Done: file's last balance and day); the "Not reconciled" badge rule; adding a transaction during a run creates a cleared row at Finish and moves the difference live; edit/delete of uncleared rows, bank-file rows refuse deletion; Cancel discards every staged change; difference arithmetic (including opening balance, statement-day filtering, ticks live);
  Finish at 0 sets ticked rows and stores the reconciliation; Finish disabled at ≠ 0; correction path
  creates one cleared `isBalanceCorrection` row dated the statement day and excluded from reports;
  drift after editing a cleared row; unticking a bank-file row needs confirmation; stale holds listed.
- `R-CLR-6`: cash compares the whole balance; "Tick all up to the date" then Finish marks all cleared;
  a difference of −5.00 gives a −5.00 correction.
- `R-CLR-7`: PKO import creates cleared rows and uncleared holds; Saldo import clears everything;
  settled hold becomes cleared; a hand-typed row matching a bank row defaults to Link and ends cleared
  with the fingerprint and `bookedDay` set, other fields untouched; Skip leaves it uncleared; an
  existing cleared row keeps the Skip default; re-import of the same file changes nothing; undo restores
  every changed row and removes created ones; headless run equals the wizard run with defaults.
- `R-CLR-8`: bulk Keep/Mark settled/Delete over selected items; Mark settled keeps the row uncleared and not pending, undo restores it; boundary table for `staleHoldDays` (4 days no, 5 days yes), the coverage window (before
  first booked day − 3 no), a settled hold is not raised, a re-listed hold is not raised, another
  account or Saldo row is not raised; Import disabled until decided, Keep all; Delete commits and Undo
  re-inserts; Edit keeps it uncleared and honours "Still pending"; history line counts; 0 holds shows
  "none found".
- `R-CLR-9`: a synthetic statement whose balances chain → no gap; one day removed → one gap with the
  right signed amount; two gaps; unordered rows within a day; repeated equal balances and zero amounts;
  holds ignored; a one-row file; file start equals / differs from the account's cleared balance;
  Saldo file → no check; warning does not block `commit`; Remove skips the chosen row and the history line counts it; Leave all.

## 4. Work-package split (proposal)

Migration v19 and `Schema.swift` are shared files (orchestrator). Three WPs, in this order:

1. **N6a — cleared core** (S–M): migration v19 + backfill, `Txn` fields, `Reconciliation` table and
   repository (`TxnRepository` mark/unmark, `ReconciliationRepository`, cleared-balance query),
   clearing in the import pipeline (`CommitBuilder`, snapshots, headless defaults, history counts),
   tests for `R-CLR-1/2/3/7`. Owned paths: `AbacusDomain/Model`, `AbacusStore` (repositories, new
   migration entry by the orchestrator), `AbacusImport/Pipeline` + `Dedupe`, `abacus-import`.
2. **N6b — Reconcile UI** (M, after N6a): list indicator, filter, mark actions, editor checkbox,
   account inspector with the "Not reconciled" badge, Reconcile setup step and working screen (tick, add, edit, delete, mark settled, correction) incl. cash and drift, Done-step offer, Mark settled on Transactions; `R-CLR-4/5/6`.
   Owned paths: `AbacusFeatures/…` new `Reconcile/`, `App/macOS` list and inspector hooks.
3. **N6c — import checks** (M, can start with N6a's detector code in parallel): pure detectors
   `StaleHolds` and `BalanceContinuity` in `AbacusImport` (testable without UI), then preview cards, the Needs review sub-tabs (Decisions, Pending payments with bulk actions, Balance gaps),
   history line; `R-CLR-8/9`. The delete/edit decisions need N6a's snapshots.
   Owned paths: `AbacusImport/Pipeline`, `AbacusFeatures/Import`, `App/macOS/Import`.

N6c's wizard changes and N6b's list changes touch different files; the only shared one is the
Transactions row view (N6b). Run N6a first, N6b and N6c in parallel afterwards.

## 5. Open questions (each with the proposed default)

| # | Question | Proposed default |
|---|----------|------------------|
| Q1 | Place rows by booking day (`bookedDay`) for the statement-balance check? | Yes (`R-CLR-3`); otherwise the purchase-day dating gives false differences. |
| Q2 | When a bank row matches a hand-typed uncleared row, default to **Link** instead of today's Skip? | Yes, only for hand-typed and uncleared rows; Saldo/cleared rows keep Skip. |
| Q3 | Stale threshold: how many days after the value day is a hold "stale"? | 5 days (`staleHoldDays`, one constant). |
| Q4 | Should "Keep pending" stop asking? | No: it is asked again next import while the hold still qualifies, so a forgotten one cannot hide. A "don't ask again" needs one more column; not in v19. |
| Q5 | Finish with a non-zero difference? | Allowed only via an explicit "Add correction X and finish"; otherwise Finish is disabled. |
| Q6 | Lock reconciled rows against edits? | No lock; a warning on edit plus the drift note (`R-CLR-3`, `R-CLR-5`). |
| Q7 | Backfill: are "Balance correction" rows cleared? | Yes. |
| Q8 | Persist half-done ticks between sessions? | No: held in memory, confirmation on leaving; Finish saves all at once. |
| Q9 | Click on the list indicator toggles cleared? | No (context menu, Mark buttons and the editor only). |
| Q10 | Cash reconciliation compares the whole balance, not only cleared rows? | Yes (`R-CLR-6`). |
| Q11 | Balance-continuity opening check against the account: warning or silent? | Warning with the difference when the account has earlier cleared rows; silent confirmation when equal. |
| Q12 | Sign of the typed balance for liability accounts (credit card)? | The Abacus sign (a card in debt is negative), with a hint under the field; the owner can flip it later if the statement convention is confusing. |
| Q13 | Settled holds are not tagged with their batch today, so Undo does not revert them. Close that gap as part of N6a (snapshot) for the cleared/pending state? | Yes, snapshot only; no change to how settling works. |
| Q14 | Per-side flags (`isToCleared`) instead of one flag per transaction? | Yes: a transfer is cleared on one account when only that statement was imported. One flag would mark both sides cleared falsely. |
| Q15 | The file shows a balance gap (the balance after one row does not match where the next row starts, so rows are missing between them). What can be done with the two rows next to the gap? | Leave them (import as the file says) or Remove them (do not import them). Default Leave. Removing is only useful if you distrust those rows; importing the same period again later is safe (known rows are recognised). Say if "Remove" should mean something else, e.g. everything after the gap. |
| Q16 | "Mark settled" on a pending payment: it stops being pending. Should it also become cleared (confirmed by the bank)? | No. No bank file has shown it, so it stays "not confirmed" and appears in the Reconcile list until a statement or a bank row confirms it. The alternative is to clear it at once. |
| Q17 | When does the "Not reconciled" badge show on an account? | When the account has bank-confirmed rows newer than its last reconciliation, or was never reconciled. It is only a small label (account list and account window): no pop-up, no notification. Alternatives: show it only after 30 days without reconciling, or not at all. |

## 6. What is not in N6

Automatic reconciliation (ticking rows to reach a statement balance by itself), statement PDFs or
other formats, a reconciliation history screen (the `reconciliations` rows exist for a later one),
changing how PKO/Saldo rows are matched (`R-IMP-4` is reused as is), and any change to balances or
reports. The approved prototypes depend on a canvas runtime (`support.js`) that is not in the
repository; `N6-reconcile.dc.html` is self-contained and opens in any browser.
