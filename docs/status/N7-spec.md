# N7 — App lock: proposed TA text (spec step)

_Written 2026-11-03. No app code. For owner review; the orchestrator folds the approved text into
`docs/REQUIREMENTS.md` (new §4.7 `R-LOCK`, a line in §4.6/§5 as noted below). Prototype:
`docs/design/N7-lock.dc.html` (synthetic data, standalone page: open it in any browser; it does not
need the canvas runtime the older prototypes use)._

Inputs: `docs/ROADMAP.md` §5 N7 (owner's defaults, D70), `docs/status/N4.md` §7 (encryption research:
FileVault now, the lock is a UI gate), `docs/DECISIONS.md` D66/D70, TA §4.6 and §6.

## 0. What this is, in one paragraph

An optional lock that hides Abacus's window behind the Mac's own authentication (Touch ID, Apple
Watch or the login password) when you open the app, after you have not used it for a while, when the
Mac sleeps and when the screen locks. It protects against **someone walking up to your unlocked
Mac**. It is **not** database encryption and does not protect the file, backups, the MCP server or
the import command (N4: FileVault covers a lost or stolen Mac). Off by default.

## 1. Checked here vs not checked

**Verified on this Mac (macOS 26, Xcode 27 toolchain):** a command-line binary signed only ad-hoc
(`Signature=adhoc`, linker-signed, no entitlements, no bundle, no Keychain use) links
`LocalAuthentication` and `LAContext().canEvaluatePolicy(...)` returns `true` for both
`.deviceOwnerAuthentication` and `.deviceOwnerAuthenticationWithBiometrics` (biometry type =
Touch ID), with no error. So availability checks do not need a Developer ID, a team or a
Keychain access group.

**Not verified (the lane must test on the real app and record the result in `docs/status/N7.md`):**
- The actual `evaluatePolicy` prompt from the ad-hoc signed **Abacus.app** (I did not trigger the
  Touch ID dialog from a script). Expected to work: `LocalAuthentication` identifies no code
  requirement and stores nothing; unlike a Keychain item (N4 §5) nothing is bound to the app's
  designated requirement, so a rebuild changing the identity cannot break it. **[unverified]**
- Behaviour on a Mac without Touch ID (policy falls back to password, expected) and with the lid
  closed on an external display (biometrics unavailable, password prompt, expected). **[unverified]**
- The exact notification names for "screen locked" and "screensaver started". Documented API exists
  for sleep and display sleep (`NSWorkspace.willSleepNotification`, `.screensDidSleepNotification`);
  screen lock and screensaver are usually observed through the distributed notifications
  `com.apple.screenIsLocked`, `com.apple.screenIsUnlocked`, `com.apple.screensaver.didstart`, which are
  long-used but **not documented by Apple**. Lane verifies each by locking the screen and starting the
  screensaver, and falls back to display-sleep if one is missing. **[unverified]**
- Whether macOS's saved window state (Resume) writes a window snapshot to
  `~/Library/Saved Application State/` that could show content while the app is locked
  (see `R-LOCK-9`). **[unverified]**
- Whether hiding an attached sheet window (alpha 0 + ignore mouse) behaves well on macOS 26 for
  SwiftUI sheets and for confirmation dialogs (`R-LOCK-11`). **[unverified, spike first]**

## 2. Proposed requirements (`R-LOCK`)

Convention as in the TA: ID, text, then (indented) tests. "Unit" = AbacusKit test with fakes;
"Manual" = checklist run by the owner/lane on the built app (no UI test target exists for this).

### 4.7 App lock — `R-LOCK`

- `R-LOCK-1` **Authentication.** Unlocking uses the system's `LocalAuthentication` with the
  `.deviceOwnerAuthentication` policy: Touch ID or Apple Watch when available, otherwise (or on
  "Use Password…") the Mac login password. Each attempt uses a fresh `LAContext` with no reuse
  window. The lock stores **no secret and uses no Keychain item**; it must work unchanged with an
  ad-hoc signed build whose code identity changes on every rebuild (N4 §7).
  - Unit: `Authenticator` protocol with a fake; model never touches `LAContext` directly. Manual:
    Touch ID path, password path, on an ad-hoc build, across two rebuilds.
- `R-LOCK-2` **Off by default; Settings switch.** New Settings tab **Security** (prototype) holds the
  switch "Require Touch ID or password to open Abacus", the **Lock after** picker and **Lock now**.
  Turning the lock **on** first runs one authentication ("prove it works"); if it fails, is
  cancelled, or is unavailable the switch stays off and a message says why. Turning it **off**, and
  **increasing** the idle time, also require a successful authentication (someone at an unlocked Mac
  cannot weaken the lock without the password). Decreasing the idle time needs none.
  - Unit: enable requires `.success`; cancel/failure/unavailable leave state unchanged with the
    right message; disable and idle-increase require auth, decrease does not.
- `R-LOCK-3` **Per device, not synced, not in backups.** The setting (enabled, idle minutes) is kept
  in `UserDefaults` on this Mac, **not** in the `app_setting` table: that table is part of the
  database, which is backed up (R-SET-2), moved with the data folder and will be synced (D66). A
  restore, a data-folder change or a second device must not turn the lock on or off.
  - Unit: the lock settings store reads/writes only its `UserDefaults` suite keys
    (`appLock.enabled`, `appLock.idleMinutes`); a backup export/restore round-trip leaves them
    untouched (test against the existing `Backup` with a scratch suite).
- `R-LOCK-4` **Lock after.** Picker: 1 minute, **5 minutes (default)**, 15 minutes, 30 minutes,
  1 hour, Never (idle never locks; launch, sleep, screen lock and Lock now still do).
  - Unit: each value maps to the configured interval; unknown stored value falls back to 5.
- `R-LOCK-5` **Lock triggers** (when the lock is on): (a) **at launch**, before any content is
  shown; (b) **idle**: the time since the last user input to Abacus (key, click, scroll) reaches the
  picker value, counted also while Abacus is in the background or hidden; (c) **sleep**: system sleep
  and display sleep; (d) **screen lock and screensaver start**; (e) **Lock now**: menu item
  "Lock Abacus" (⌥⌘L, proposed) and the Settings button. A trigger while already locked does nothing
  (idempotent). The idle deadline uses a monotonic clock that keeps counting through sleep, and the
  deadline is re-checked when the app becomes active, so a missed timer cannot leave the app
  unlocked.
  - Unit (fake clock + fake event source): lock at launch; lock exactly at the deadline, not before;
    input resets the deadline; background time counts; sleep/display sleep/screen lock/screensaver/
    manual each lock; duplicate triggers produce one lock; picker "Never" disables idle only;
    deadline re-check on activation locks when overdue; trigger while an unlock prompt is open
    cancels the prompt and stays locked. Manual: each real trigger on the built app.
- `R-LOCK-6` **First launch after turning it on is not locked.** Enabling authenticates already; the
  window stays usable and the idle clock starts.
  - Unit: enabling leaves state unlocked and sets `lastInput = now`.
- `R-LOCK-7` **Lock screen.** An opaque view covers the whole window (prototype): lock icon, "Abacus
  is locked", the reason ("Locked after 5 minutes idle."), an **Unlock** button, **Quit Abacus**,
  and a one-line note. When the lock appears and Abacus is the active app it **asks to authenticate
  once automatically**; it does not re-prompt in a loop. After a cancel it shows "Unlock was
  cancelled. Click Unlock to try again." and waits. It prompts again when the user clicks Unlock, and
  once more when Abacus becomes active again after having been inactive while locked (no prompt
  while asleep or the screen is locked). On success the previous screen reappears exactly as left
  (section, filters, scroll, open import wizard). Standard Quit (⌘Q) works while locked.
  - Unit: state machine `locked → prompting → (unlocked | cancelled | failed | unavailable)`;
    exactly one automatic prompt per lock and per activation; no prompt while the screen is locked
    or asleep; success returns `unlocked`. Manual: screenshots of each state against the prototype.
- `R-LOCK-8` **Authentication fails or is unavailable.** *Cancelled* (`userCancel`, `systemCancel`,
  `appCancel`): stays locked, "cancelled" message, Unlock button. *Failed* (wrong password; the system
  dialog normally handles retries, an `authenticationFailed` result is shown as "That didn't work"):
  stays locked. *Unavailable* (`canEvaluatePolicy` false or an error such as `passcodeNotSet`,
  `notInteractive`, anything unexpected): stays locked, shows "Authentication isn't available right
  now…" with **Try again** and **Quit Abacus**. **There is no bypass or "turn the lock off" button on
  the lock screen**: a bypass would make the lock meaningless. Recovery if the owner is locked out
  of the system method for good: quit and set the preference from Terminal
  (`defaults write <bundle id> appLock.enabled -bool NO`), documented in the README. This is
  acceptable because the lock is only a UI gate and the owner owns the Mac (N4 §7).
  - Unit: each `LAError` code maps to the right state and message; unavailable never unlocks;
    unknown errors are "unavailable"; Try again re-queries availability.
- `R-LOCK-9` **What is hidden while locked.** Everything the app draws: the main window and the
  Settings window (both show the lock screen); the window contents seen in **Mission Control /
  Exposé thumbnails** and screenshots (they show the lock screen because it is composited into the
  window itself); any **sheet or alert** (`R-LOCK-11`); the **menu bar**: items that open, create,
  import, export, back up, restore or otherwise act on data are disabled (no menu shows data in the
  first place); **window titles** and the Window menu never contain data (titles stay "Abacus");
  **keyboard input** is not delivered to the hidden screens (shortcuts such as ⌘N do nothing). The
  **Dock icon** is the normal icon with no badge, and the **app switcher** (⌘Tab) shows only the
  icon, so neither leaks content. If macOS's saved window state turns out to store window images,
  restorable state is disabled for the window (spike item, §1).
  - Unit: `LockModel.isLocked` drives a `commandsEnabled` value that is false while locked (tested
    on the model). Manual checklist: Mission Control, ⌘Tab, Dock, a screenshot, VoiceOver reading
    the window (the hidden screens are not in the accessibility tree: `.accessibilityHidden`), ⌘N and
    ⌘, while locked, Window menu.
- `R-LOCK-10` **Honest scope, stated in the UI.** The Security tab says: the lock hides the
  window; it does not encrypt data; the database file stays readable by other apps and tools; the
  **MCP server (`abacus-mcp`) and `abacus-import` are separate processes that open the file directly
  and are **not** gated** by the lock; FileVault protects the disk. The README says the same. This
  is **not database encryption**: that was researched in N4 (decision: FileVault now; SQLCipher only
  after Developer ID signing, with the key obtained at unlock). Nothing in N7 may be described as
  "encrypted".
  - Unit: none (text). Manual: wording check against this section.
- `R-LOCK-11` **Open editors, sheets and unsaved edits.** Locking never discards work. While locked,
  attached sheets (transaction editor, account/category sheets, confirmation dialogs) are hidden and
  ignore input, and come back with their unsaved edits unchanged after unlock. Recommended
  mechanism (spike first): at lock, hide every attached sheet window of the app's windows (alpha 0,
  ignore mouse events) and restore it at unlock; the views underneath stay mounted, disabled and
  hidden from accessibility. Fallback if that is unreliable: dismiss the sheet after saving its draft
  in memory and reopen it with the draft after unlock. System **open/save panels** (for example
  "Choose file…" in the import wizard) are separate system UI and may stay on screen; they show file
  names, not Abacus data (accepted, listed under open questions).
  - Unit: the draft-stash fallback (if used) round-trips a draft. Manual: lock with the editor
    open and a typed amount, unlock, the sheet and the typed text are back; same for the import
    wizard at "Review" and for a confirmation dialog.
- `R-LOCK-12` **Background work continues.** Locking does not cancel or pause an import, a rate
  refresh, a backup (N1) or a headless MCP write. Their outcome is shown after unlock in the usual
  places; while locked, **no alert, sheet, notification or Dock bounce carries data** (a generic
  "Abacus finished a task" is allowed only if it contains no amounts, names or counts). An import
  wizard in progress keeps its state (`R-LOCK-11`). Database access, the repositories and `AppSession`
  are unchanged by the lock.
  - Unit: locking while a fake long task runs leaves it running; the task's completion while locked
    queues its message and delivers it on unlock. Manual: start an import, let it lock, unlock.
- `R-LOCK-13` **Architecture hook (N4 §7).** Lock state is an app-level model (`AppLockModel`:
  `isLocked`, `state`, `reason`) owned beside the session host and independent of the database: the
  database is opened as today and **not** lazily at unlock. A later encryption step may add an
  "on unlock" step (fetch a key, then open) without changing the lock UI. The model sees time, input
  and system events only through injected protocols (`Authenticator`, `Clock`,
  `LockEventSource`), so it is fully unit-testable and a launch flag can run the UI with a fake
  authenticator for screenshots.
  - Unit: the whole `R-LOCK-5…8` suite above, with fakes.

Edits to existing TA lines (orchestrator): add `R-SET-4` "Security tab: see `R-LOCK`"; in §6 or the
glossary mention "lock screen". `R-NF-1` is unaffected (the lock is offline).

## 3. Settings screen (see prototype)

New tab **Security** (4th tab after Data): App lock checkbox with hint (off by default; turning it
on asks you to authenticate), **Lock after** picker (disabled while off), **Lock now** button
(disabled while off) with the shortcut, "Uses: Touch ID, Apple Watch or your Mac password — chosen
by macOS. This device only: not part of backups or sync", and the card "What the lock does not do".
A cancelled or failed authentication in Settings shows an amber banner at the top of the tab. The
lock screen states: idle/prompting ("Waiting for Touch ID or password…"), cancelled, failed,
unavailable (amber, Try again + Quit). The Settings window, if open when the lock triggers, shows the
same lock screen.

## 4. Edge cases

1. **Lock during an unlock prompt** (sleep, screen lock): cancel the prompt, stay locked, prompt again
   on wake/activation.
2. **Two windows** (main + Settings): one `AppLockModel`; both show the cover; unlocking one unlocks
   both.
3. **Window closed while locked, app still running**: reopening from the Dock shows the lock screen
   (lock state is app-level, not window-level).
4. **Launch with the screen locked / launched at login**: starts locked; no prompt until the screen
   is unlocked and the app is active.
5. **Fast user switching**: another user's session active → treated as screen lock (the session
   resign notification; verify).
6. **Clock changes / timezone**: monotonic clock for idle; a wall-clock change cannot unlock or
   lock early.
7. **Biometrics lockout** (too many failed Touch ID tries): the system moves to password itself under
   `.deviceOwnerAuthentication`; nothing to do.
8. **No Touch ID hardware, or clamshell mode**: password prompt; message unchanged.
9. **Quit while locked, relaunch**: locked again (launch trigger). **Force quit/crash**: same.
10. **Turn-off prompt cancelled**: lock stays on, banner explains.
11. **Idle value in the future after a downgrade/old defaults**: invalid values fall back to 5.
12. **Debug/preview launch flags** (`-AbacusPreviewData`): the lock is off unless `-AbacusLockTest`
    is given (lane-defined), so screenshots and previews never prompt.
13. **Menu-bar extra / App Intents (N8, deferred)**: when built they must obey the lock (a locked app
    refuses them). Recorded here so N8 inherits it.
14. **Hidden app (⌘H) or minimized window**: not a trigger by itself; idle counts as usual.
15. **A running import finishes while locked**: result waits (`R-LOCK-12`).

## 5. Work-package split (proposal)

Size S overall; two WPs so the risky UI part is small and merged last.

| WP | Scope | Owned paths | Notes |
|---|---|---|---|
| **N7a Lock core** | `AppLockModel`, state machine, `Authenticator` + `LAAuthenticator`, `Clock`, `LockEventSource` (+ `SystemLockEventSource` over `NSWorkspace`/distributed notifications, `NSEvent` input monitor), `LockSettingsStore` (`UserDefaults`), error mapping, all unit tests with fakes, spike notes | New files only: `AbacusKit/Sources/AbacusFeatures/Lock/**`, `AbacusKit/Tests/AbacusFeaturesTests/Lock/**` (or the suite's existing location) | No contended files. Can start immediately after approval. Includes the §1 "not verified" spikes that need no UI (notification names, LAError codes) |
| **N7b Lock UI** | `LockView` (cover), the gate in `SessionScope`/`AbacusApp.swift` (both scenes), disabling commands in `AppCommands`, "Lock Abacus" menu item, Security tab in `SettingsView`, sheet hiding or draft-stash (`R-LOCK-11`), saved-state check, screenshots | **Contended:** `App/macOS/AbacusApp.swift`, `App/macOS/Settings/SettingsView.swift`, `AppCommands`, `AbacusKit/.../Shell/AppSessionHost.swift` (only to own the model) | **Merge last**, after N2/N1/N5/N6 UI lanes have landed; rebase on `main` first. Depends on N7a. Needs the owner's visual check of the built app |
| Docs | README lock + recovery text, `STATUS.md`/`PLAN.md` ticks | orchestrator | |

If a single lane is preferred, run N7a then N7b in one worktree; the rule stays: touch the contended
files in the last commits and merge last.

## 6. Open questions (proposed default each)

| # | Question | Proposed default |
|---|---|---|
| Q1 | Idle options and default | 1 / **5** / 15 / 30 / 60 min and Never (as approved: default 5) |
| Q2 | Does idle count while Abacus is in the background? | **Yes** (time since the last input to Abacus); a "lock when I switch to another app" option is not offered |
| Q3 | Require authentication to turn the lock off or lengthen the idle time? | **Yes** (R-LOCK-2) |
| Q4 | Shortcut for Lock now | **⌥⌘L** in the Abacus menu (not checked for clashes; the lane checks) |
| Q5 | Sheets while locked: hide in place, or dismiss and restore the draft? | **Hide in place** (spike first), fallback draft-stash |
| Q6 | Allow a generic "task finished" notification while locked? | **No notifications at all** in N7 (nothing to leak, simplest) |
| Q7 | Should the lock also block `abacus-mcp`/`abacus-import`? | **No**, and say so (N4 §7); blocking would need the key-delivery design from the encryption step |
| Q8 | Show a read-only "FileVault is on/off" hint in the Security tab? | **Yes if cheap**, as a separate small item (N4 §6.1); not part of N7 |
| Q9 | Open/save panels left on screen while locked | **Accept** (file names only); revisit if the owner objects |
| Q10 | Lock-out recovery | `defaults write` line in the README, no in-app bypass (R-LOCK-8) |
| Q11 | Disable restorable window state to avoid saved window images? | **Yes, if the spike shows images are saved** |
| Q12 | Security as a new 4th Settings tab, or a section in General? | **New tab** (room for the FileVault hint later) |

## 7. Manual verification checklist for N7b (owner or lane)

Turn on (Touch ID); cancel the enable prompt (stays off); idle 1 minute → locks; sleep and wake
→ locked; ⌃⌘Q screen lock and unlock → locked; screensaver start → locked; Lock now (⌥⌘L); Mission
Control thumbnail shows the lock screen; ⌘Tab and the Dock show no content; screenshot while locked
shows the cover; ⌘N and ⌘, do nothing while locked; editor open with typed text survives; import
running survives; cancel the unlock prompt (message, no loop); lid closed on an external display
(password prompt); quit while locked and relaunch (locked); turn off needs authentication;
VoiceOver finds no data while locked; rebuild the app and confirm nothing about the lock broke.
