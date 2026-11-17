# N7d — Lock screen polish (lane status)

Branch `wp/N7d-lock-polish`. Scope: QA-N findings **L2** and **L3** (`docs/status/QA-N.md`), R-LOCK-11.
No schema change, no shared files.

## Done
- **L3** (`App/macOS/Lock/LockView.swift` `runPlan`): the `-AbacusLockTestPlan` log line is written after
  `LockWindowShield.refresh()` has applied the new state (the shield otherwise applies it on its
  observation callback, a run-loop turn later). The line also shows `hidden <n>`. Log now matches the
  screen: lock → sheet `alpha 0.0`, title "Abacus"; unlock → `alpha 1.0`, section title.
- **L2** (`App/macOS/Lock/LockWindowShield.swift`, `LockView.swift`). Cause, found by dumping the parent
  window's frame view: AppKit adds `NSSheetEffectDimmingView` over the whole parent window (above the
  content, with masking views around the traffic lights) while a sheet is attached; that grey layer, plus
  the parent not being key, made the lock screen look disabled.
  - Making the parent key was tried and does not work: AppKit refuses `makeKey` on a window with an
    attached sheet (`isKeyWindow` stays false, the hidden sheet stays key). Left as is; it is also what
    keeps keys away from the parent's content.
  - Fix: while the shield hides a sheet, the dimming views of its parent (matched by class name
    `…SheetEffectDimming…` among the frame view's subviews) are hidden, and restored on unlock. They only
    draw, so input handling does not change.
  - `LockView` draws its controls as in a key window (`controlActiveState = .key`) while
    `LockShieldState.shared.hidesSheets` is true: Unlock is the blue default button, Quit is normal.
  - R-LOCK-11 unchanged: the sheet keeps alpha 0, `ignoresMouseEvents`, hidden content view (no drawing,
    clicks, keys or accessibility); the event monitor still routes Unlock / Quit / Return and swallows
    other keys.

## Verified
- swift test (with and without `ABACUS_SAMPLES`): green. App build (`build.noindex/fresh`).
- In-app snapshots, scratch DB under `build.noindex/qa/db/`, `CFFIXED_USER_HOME=build.noindex/qa/home`,
  `-AbacusLoadSampleData YES -AbacusLockTest YES -AbacusLockTestPlan "2:unlock,5:lock,8:unlock"
  -AbacusSection events -AbacusOpenSheet editEvent` (script `build.noindex/qa/run.sh`, not committed).
  Screens in `docs/status/N7d-screens/`:
  - `lock-0-before-fix-light.png` — before: grey dimmed window, grey buttons.
  - `lock-1-sheet-open.png` — unlocked, editor sheet open (snapshot at 3.5 s).
  - `lock-2-locked-light.png`, `lock-2-locked-dark.png` — locked over the hidden sheet: no dimming,
    blue Unlock, normal text (6.5 s).
  - `lock-3-unlocked-sheet-back.png` — after unlock: sheet, values, toolbar and the sheet dimming back (10 s).

## Not done / open
- Over a hidden sheet the title bar shows no traffic lights while locked (the title bar container is
  hidden with the toolbar; before the fix only the dimming's masking holes showed white dots). Quit
  Abacus and ⌘Q / ⌘H / ⌘M still work. Not changed.
- The match on AppKit's private class name (`NSSheetEffectDimmingView`) is best effort: if a future
  macOS renames it, the lock screen falls back to the old dimmed look (cosmetic only, no security effect).
- Real clicks on Unlock / Quit under a hidden sheet still need the owner's hand check (no Accessibility
  permission for synthetic input here), as in N7c.
