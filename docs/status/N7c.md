# N7c — App lock finish (lane status)

Branch `wp/N7c-lock-finish`. Scope: `docs/status/N7.md` "Not done / open"; spec `docs/status/N7-spec.md`.
No schema change. Merge last (N7 rule), after rebasing on `main`.

## Done
- **R-LOCK-11 sheets and alerts** (`App/macOS/Lock/LockWindowShield.swift`). Spike: SwiftUI `.sheet` (and the
  Accounts group prompt) is a `SheetPresentationWindow` (SwiftUI bundle) attached to its window
  (`sheetParent`); `.alert` / `.confirmationDialog` are AppKit sheet panels. Hide in place (spec Q5) works:
  at lock every attached sheet / child window of AppKit, SwiftUI or the app gets alpha 0, ignores the mouse
  and its content view is hidden (no drawing, no clicks, no keys, out of the accessibility tree); the
  SwiftUI views stay mounted. On unlock alpha, mouse, content and the first responder (the text field, not
  the shared field editor) come back. Nothing is dismissed, so drafts survive. Sheets that open while
  locked are hidden too (window update / key / will-begin-sheet notifications). Windows of other bundles
  (a system authentication dialog, if it ever came in-process) are never hidden.
  - Finding: a window with an attached sheet is modal, so AppKit drops clicks on the lock screen under a
    hidden sheet. While anything is hidden a local event monitor routes clicks on the lock screen's Unlock /
    Quit buttons (frames reported by `LockView`), and Return / Enter / Space to unlock; every other key is
    swallowed (the hidden sheet stays the key window: typing, Return = Save and ⌘-shortcuts must not reach
    it). ⌘Q, ⌘H, ⌘M and title-bar drags pass. No hover / pressed look on the buttons in that case.
  - Fallback draft-stash (Q5) not needed.
- **Toolbar while locked**: `LockGate` hides the window toolbar (`.toolbarVisibility(.hidden, for:
  .windowToolbar)`): no section title, currency pills or "New transaction". Top-level window titles are set
  to "Abacus" while locked (Window menu, Mission Control) and restored on unlock.
- **R-LOCK-9 saved state spike**: on macOS 27 there is no `~/Library/Saved Application State` for Abacus;
  AppKit keeps it in `~/Library/Daemon Containers/<id>/Data/Library/Saved Application State/<uuid>.savedState`
  (`windows.plist`, `data.data`, `window_N.data`; the `window_N.data` files of other apps are 270–350 KB, i.e.
  window images). Abacus's folder was empty after a clean quit (default "close windows when quitting"), but
  AppKit writes it while the app runs. Decision (spec Q11): while the lock is **enabled**, top-level windows
  are not restorable (`isRestorable = false`), so no image of unlocked content is saved; back to restorable
  when the lock is turned off. Not checked: whether the window frame is still remembered across launches with the lock on.
- **R-LOCK-12**: `AppLockModel.whenUnlocked { … }` runs at once when unlocked, otherwise queues and runs in
  order after a successful unlock (or when the lock is turned off); a cancelled prompt delivers nothing. The
  lock never pauses work. The import wizard keeps its result in its own (hidden, mounted) view, so an import
  finishing while locked shows its result after unlock without a call site. Nothing else in the app shows a
  message from background work today, so no call site was wired.
- README: "App lock" section (scope, not encryption, FileVault, `defaults write
  io.github.andrii-habchak.Abacus appLock.enabled -bool NO`).
- `-AbacusLockTest` / preview lock preferences used a `UserDefaults` suite that writes
  `~/Library/Preferences/abacus.lock.test.<uuid>.plist` in the **real** home (suites ignore
  `CFFIXED_USER_HOME`); the suite file is now removed at quit. Older leftovers from earlier runs
  (`abacus.lock.test.*.plist`, 65 bytes each) are still there; the owner can delete them.
- DEBUG `-AbacusLockTestPlan "2:unlock,4:lock"` (with `-AbacusLockTest YES`): scripted unlock/lock steps
  for snapshot checks; logs attached windows, titles and restorable state with `NSLog`.

## Verified
- swift test with `ABACUS_SAMPLES` (all suites green), app build.
- Tests: `AbacusKit/Tests/AbacusFeaturesTests/Lock/LockedMessageQueueTests.swift` (4 tests, R-LOCK-12).
- In-app snapshots on a scratch DB (`-AbacusDatabasePath <scratch> -AbacusLoadSampleData YES`,
  `CFFIXED_USER_HOME=<scratch>`): Events editor sheet (`-AbacusOpenSheet editEvent`) opened while locked →
  hidden; unlock → visible; lock → hidden (no sheet, no toolbar in the capture); lock + unlock → sheet back
  with its values. Accounts group prompt hidden while locked. Plain lock screen (dark) with no toolbar.

## Not done / open (owner)
- Real Touch ID / password prompt on the built app (and that it is never hidden by the shield).
- Clicking Unlock / Quit under a hidden sheet and typing into a sheet after unlock: no Accessibility
  permission for synthetic input here, so only the code path is in place; owner checks by hand (open the
  transaction editor, type an amount, ⌥⌘L, click Unlock, the amount is still there).
- A sheet opening while locked is hidden on the next window update; a single frame of it may be drawn first.
- Mission Control thumbnail, screen lock / screensaver notification names (from N7) still unverified.
- Request to other lanes: show messages from background work through `lock.whenUnlocked { … }` (the
  `AppLockModel` is in the SwiftUI environment).
