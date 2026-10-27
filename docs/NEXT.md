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
   gate from `AGENTS.md` — `swift test` in `AbacusKit/` and the app build (`-derivedDataPath
   build.noindex`), both with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Real-data tests run with
   `ABACUS_SAMPLES=$PWD/samples/private` and print counts only.
3. State as of 2026-10-27: everything planned is merged on `main` — v1.0.0 (tagged), then the
   owner-review rounds C3–C14 and the stability round S1–S3 (see `docs/PLAN.md` Phases 3c–3e).
   `main` is version **1.2.1** (build 4); the owner is testing `dist/Abacus-1.2.1.dmg`; it is
   **not tagged**. Done and no longer to do: the Import window height (C3) and the v1.0.0
   release. Next, in this order:
   a. **Owner feedback on 1.2.1** — triage it into bugs vs features, stability and
      performance first (owner rule, D54). Reproduce crashes from
      `~/Library/Logs/DiagnosticReports/Abacus-*.ips` (stacks only) and with the DEBUG soak
      (`-AbacusSoak YES -AbacusHangWatch YES` on a scratch database with
      `-AbacusLoadLargeSampleData YES`). Fix on lanes, merge, rebuild the DMG.
   b. **Release v1.2.1** on the owner's OK: set the CHANGELOG date, commit, tag `v1.2.1`, push
      the tag; report DMG path, size and SHA-256. Never commit the DMG. The owner publishes the
      GitHub release.
   c. Deferred items in `docs/STATUS.md` ("Next" 3, "Open items") only if the owner asks.
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
  with Load Sample Data (synthetic) for anything visual; README screenshots use only that.
- Git identity is the repo's own (`andrii-habchak`, personal email) and the remote uses the SSH
  alias `github-vigil`; never change them.
- GitHub CI is not used (free account, D37); the local gate decides.
- Do not re-open settled decisions in `docs/DECISIONS.md` without the owner; ask the owner for
  anything not covered by the docs.

When you finish or pause, update `docs/STATUS.md` so the next session can continue from it, and
give the owner a short summary: what changed, what is verified, what needs their decision.
