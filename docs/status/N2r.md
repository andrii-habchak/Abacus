# N2r — app side of cross-process database changes

Branch `wp/N2r-app-refresh`. Spec: `docs/status/N2.md`, "App-side spec for cross-process refresh"
items 1–4.

## Done

- **1–3 Watcher** (`AbacusFeatures/Shell/DatabaseChangeWatcher.swift`), started by
  `AppSession.start()` and stopped by `AppSession.stop()` (so a data-folder switch moves it to the
  new session). Only a database file is watched (in-memory previews/tests: nothing starts).
  - Poll about once a second on a dedicated read-only connection, only while
    `NSApplication` is active (`didBecomeActive` / `didResignActive` observed inside the watcher;
    `AbacusApp.swift` untouched). Without a running `NSApplication` (command-line tests) nothing
    is polled.
  - Darwin notification `io.github.andrii-habchak.Abacus.database-changed` via
    `notify_register_dispatch` → the same check at once.
  - Becoming active → the same check at once (forced).
  - Reload = `AppSession.databaseChangedElsewhere()`: settings, transaction list (if shown),
    dashboard (if loaded), manage screens already loaded, import wizard pickers. Log line
    `Database changed by another process; reloading screens` (subsystem
    `io.github.andrii-habchak.Abacus`, category `DatabaseChangeWatcher`).

## Interpretations (decided here, owner may revisit)

- **`data_version` on a dedicated reader also moves for the app's own commits** (the app's writer
  is "another connection" for that reader), so the N2 spec's "never for the app's own writes"
  only holds for the writer's own connection. Solution: the dedicated reader is the cheap
  1-second pre-filter; only when its value moved is `PRAGMA data_version` read on the app's
  writer connection (`writeWithoutTransaction`, no transaction). That value moves only for other
  processes' commits; it decides the reload. Own saves never reload; the writer is touched only
  after something was committed.
- "Reload when the app becomes active" is a forced check, not an unconditional reload: the screens
  reload when the file changed while the app was in the background (no flicker on every ⌘-Tab).
- Rates are not re-read on a foreign write (the tools do not write rates; a full rate-cache load
  per write would double the screen reload). The next rate refresh picks them up.
- iOS: the poll runs whenever the session runs (no `UIApplication` hook yet).

## Tests

`AbacusKit/Tests/AbacusFeaturesTests/DatabaseChangeWatcherTests.swift` — two connections on a
temporary file: own writes don't trigger, a foreign commit does once, the poll notices it, the
Darwin notification triggers it, in-memory is not watched, the session's list drops a row deleted
by another connection.
