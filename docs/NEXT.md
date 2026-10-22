# Hand-off: continue as orchestrator

Paste the prompt below into a new agent session started **in this repository's folder**
(`scripts/next-session.sh` prints it and copies it to the clipboard). It is self-contained: the
agent rebuilds context from the docs.

---

You are the orchestrator of the Abacus repository (personal finance tracker, native macOS app,
SwiftUI + Swift 6 + SQLiteData). Work autonomously; the owner has granted standing permission to
commit and push without asking.

1. Read, in order: `AGENTS.md`, `docs/STATUS.md` (especially "Now", "Open items" and "How to
   check the UI safely"), `docs/PLAN.md`, `docs/DECISIONS.md`. Skim `docs/REQUIREMENTS.md`
   only for the requirement IDs you touch.
2. Check the ground truth before acting: `git status`, `git log --oneline -15`, then run the
   gate from `AGENTS.md` — `swift test` in `AbacusKit/` and the app build, both with
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Real-data tests run with
   `ABACUS_SAMPLES=$PWD/samples/private` and print counts only.
3. Finish the open items in `docs/STATUS.md`, in this order:
   a. **Import window height** — the Import section makes the main window taller than the
      860 pt default. Reproduce with the in-app snapshot on a temporary database
      (`CFFIXED_USER_HOME=<scratch>` plus `-AbacusDatabasePath <scratch>/demo.sqlite
      -AbacusLoadSampleData YES -AbacusSection importFiles -AbacusSnapshotDir <scratch>
      -AbacusSnapshotName import -AbacusSnapshotDelay 5`; compare the PNG height with the
      Dashboard's). Fix it in `App/macOS/Import/`, verify, commit.
   b. **Release v1.0.0** — on final `main`: `scripts/build-dmg.sh`, `hdiutil verify` the DMG,
      set the CHANGELOG date to the release day, commit, tag `v1.0.0`, push the commit and the
      tag. Report the DMG path, size and SHA-256 to the owner. Never commit the DMG.
   c. Pick up the small deferred items listed there only if the owner asks.
4. For larger work, run lanes as described in `docs/PLAN.md` §4 (one work package per agent,
   each in its own git worktree on a `wp/<id>-<slug>` branch, progress in
   `docs/status/<id>.md`); review each lane's diff scope, run the gate, merge with `--no-ff`,
   update `docs/STATUS.md` and `docs/PLAN.md` in the same commit.

Hard rules (from the owner; also in `AGENTS.md`):
- Never mention any AI assistant or tool by name anywhere in the repository: commits, branch
  names, README, docs, code comments. No co-author trailers.
- The owner's real data lives in `~/Library/Application Support/Abacus/abacus.sqlite` and
  `samples/private/` (git-ignored). Never write to the real database from tests or tools, never
  screenshot it, never copy real names or amounts into the repository. Use temporary databases
  with Load Sample Data for anything visual.
- Git identity is the repo's own (`andrii-habchak`, personal email) and the remote uses the SSH
  alias `github-vigil`; never change them.
- GitHub CI is not used (free account, D37); the local gate decides.
- Do not re-open settled decisions in `docs/DECISIONS.md` without the owner; ask the owner for
  anything not covered by the docs.

When you finish or pause, update `docs/STATUS.md` so the next session can continue from it, and
give the owner a short summary: what changed, what is verified, what needs their decision.
