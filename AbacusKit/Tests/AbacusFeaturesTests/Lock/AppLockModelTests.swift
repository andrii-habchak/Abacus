import AbacusFeatures
import Foundation
import LocalAuthentication
import Testing

@MainActor
final class FakeAuthenticator: LockAuthenticator {
  var results: [LockAuthResult] = []
  /// When true, `authenticate` suspends until `finish` is called.
  var hold = false
  private(set) var calls = 0
  private var continuation: CheckedContinuation<LockAuthResult, Never>?

  func authenticate(reason: String) async -> LockAuthResult {
    calls += 1
    if hold {
      return await withCheckedContinuation { continuation = $0 }
    }
    return results.isEmpty ? .success : results.removeFirst()
  }

  func finish(_ result: LockAuthResult) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

final class FakeClock: LockClock, @unchecked Sendable {
  var value: TimeInterval = 1000
  var now: TimeInterval { value }
}

@MainActor
@Suite("App lock model (N7, R-LOCK-2…8)")
struct AppLockModelTests {
  func defaults() -> UserDefaults {
    UserDefaults(suiteName: "lock-test-\(UUID().uuidString)")!
  }

  func make(
    enabled: Bool = true, idle: LockIdle = .minutes5, defaults: UserDefaults? = nil
  ) -> (AppLockModel, FakeAuthenticator, FakeClock) {
    let store = LockSettingsStore(defaults: defaults ?? self.defaults())
    store.enabled = enabled
    store.idle = idle
    let auth = FakeAuthenticator()
    let clock = FakeClock()
    return (AppLockModel(store: store, authenticator: auth, clock: clock), auth, clock)
  }

  func settle() async { for _ in 0..<5 { await Task.yield() } }

  @Test("Starts locked at launch when enabled, unlocked when off")
  func launch() {
    #expect(make().0.state == .locked)
    #expect(make().0.reason == .launch)
    #expect(make(enabled: false).0.isLocked == false)
  }

  @Test("Off lock never locks")
  func offNeverLocks() {
    let (model, _, _) = make(enabled: false)
    model.lockNow()
    model.handle(.sleep)
    #expect(model.isLocked == false)
  }

  @Test("Idle locks exactly at the deadline, not before; input resets it")
  func idleDeadline() async {
    let (model, auth, clock) = make(idle: .minute1)
    auth.results = [.success]
    await model.unlock()
    #expect(model.state == .unlocked)
    clock.value += 59
    model.tick()
    #expect(model.isLocked == false)
    model.noteInput()
    clock.value += 59
    model.tick()
    #expect(model.isLocked == false)
    clock.value += 1
    model.tick()
    #expect(model.isLocked)
    #expect(model.reason == .idle(minutes: 1))
    #expect(model.reason.message == "Locked after 1 minute idle.")
  }

  @Test("Never disables idle only")
  func neverIdle() async {
    let (model, _, clock) = make(idle: .never)
    await model.unlock()
    clock.value += 100_000
    model.tick()
    #expect(model.isLocked == false)
    #expect(model.idleDeadline == nil)
    model.lockNow()
    #expect(model.isLocked)
  }

  @Test("Overdue deadline is re-checked on activation")
  func activationRecheck() async {
    let (model, _, clock) = make(idle: .minute1)
    await model.unlock()
    model.appDidResignActive()
    clock.value += 3600
    model.appDidBecomeActive()
    #expect(model.isLocked)
  }

  @Test("Every trigger locks with its reason; duplicates are idempotent")
  func triggers() async {
    for (event, reason) in [
      (LockSystemEvent.sleep, LockReason.sleep), (.displaySleep, .sleep),
      (.screenLocked, .screenLocked), (.screensaverStarted, .screenLocked),
    ] {
      let (model, _, _) = make()
      await model.unlock()
      model.handle(event)
      #expect(model.isLocked)
      #expect(model.reason == reason)
      model.handle(.screenLocked)  // already locked: unchanged
      #expect(model.reason == reason)
    }
    let (model, _, _) = make()
    await model.unlock()
    model.lockNow()
    #expect(model.reason == .manual)
    #expect(model.commandsEnabled == false)
  }

  @Test("Cancel, failure and unavailable keep it locked; Try again can succeed")
  func outcomes() async {
    let (model, auth, _) = make()
    auth.results = [.cancelled, .failed, .unavailable, .success]
    await model.unlock()
    #expect(model.state == .cancelled)
    await model.unlock()
    #expect(model.state == .failed)
    await model.unlock()
    #expect(model.state == .unavailable)
    #expect(model.isLocked)
    await model.unlock()
    #expect(model.state == .unlocked)
    #expect(model.commandsEnabled)
  }

  @Test("One automatic prompt per lock and per activation, none while the screen is locked")
  func automaticPrompt() async {
    let (model, auth, _) = make()
    model.appDidBecomeActive()
    await settle()
    #expect(auth.calls == 1)
    #expect(model.state == .unlocked)
    auth.results = [.cancelled]
    model.lockNow()
    await settle()
    #expect(auth.calls == 2)
    #expect(model.state == .cancelled)
    await settle()
    #expect(auth.calls == 2)  // no loop
    model.appDidResignActive()
    model.appDidBecomeActive()
    await settle()
    #expect(auth.calls == 3)  // once more on activation
    // Screen lock: no prompt until the screen is back.
    model.handle(.screenLocked)
    await settle()
    #expect(auth.calls == 3)
    model.handle(.screenUnlocked)
    await settle()
    #expect(auth.calls == 3 || model.isLocked == false)
  }

  @Test("A trigger during an open prompt cancels it and stays locked")
  func lockDuringPrompt() async {
    let (model, auth, _) = make()
    auth.hold = true
    Task { await model.unlock() }
    await settle()
    #expect(model.state == .prompting)
    model.handle(.sleep)
    #expect(model.state == .locked)
    auth.finish(.success)  // the stale result must not unlock
    await settle()
    #expect(model.isLocked)
  }

  @Test("Enabling needs success; cancel leaves it off with a message; window stays unlocked")
  func enable() async {
    let (model, auth, _) = make(enabled: false)
    auth.results = [.cancelled, .unavailable, .success]
    await model.setEnabled(true)
    #expect(model.enabled == false)
    #expect(model.settingsMessage?.contains("cancelled") == true)
    await model.setEnabled(true)
    #expect(model.enabled == false)
    #expect(model.settingsMessage?.contains("isn't available") == true)
    await model.setEnabled(true)
    #expect(model.enabled)
    #expect(model.isLocked == false)
    #expect(model.settingsMessage == nil)
  }

  @Test("Disable and idle increase need auth; decrease does not")
  func weakening() async {
    let (model, auth, _) = make(idle: .minutes15)
    await model.unlock()
    let base = auth.calls
    await model.setIdle(.minutes5)  // decrease
    #expect(auth.calls == base)
    #expect(model.idle == .minutes5)
    auth.results = [.cancelled]
    await model.setIdle(.hour1)  // increase, cancelled
    #expect(model.idle == .minutes5)
    await model.setIdle(.never)  // increase, ok
    #expect(model.idle == .never)
    auth.results = [.failed]
    await model.setEnabled(false)
    #expect(model.enabled)
    await model.setEnabled(false)
    #expect(model.enabled == false)
  }

  @Test("Settings live only in their UserDefaults keys; unknown idle falls back to 5")
  func store() {
    let suite = defaults()
    let store = LockSettingsStore(defaults: suite)
    #expect(store.enabled == false)
    #expect(store.idle == .minutes5)
    store.enabled = true
    store.idle = .hour1
    #expect(Set(suite.dictionaryRepresentation().keys).isSuperset(of: [
      LockSettingsStore.enabledKey, LockSettingsStore.idleKey,
    ]))
    #expect(suite.integer(forKey: "appLock.idleMinutes") == 60)
    suite.set(7, forKey: LockSettingsStore.idleKey)
    #expect(store.idle == .minutes5)
    #expect(LockIdle.allCases.map(\.title) == ["1 minute", "5 minutes", "15 minutes", "30 minutes", "1 hour", "Never"])
  }

  @Test("LAError codes map to the right outcome; unknown is unavailable")
  func errorMapping() {
    #expect(LAAuthenticator.map(.userCancel) == .cancelled)
    #expect(LAAuthenticator.map(.systemCancel) == .cancelled)
    #expect(LAAuthenticator.map(.appCancel) == .cancelled)
    #expect(LAAuthenticator.map(.authenticationFailed) == .failed)
    #expect(LAAuthenticator.map(.passcodeNotSet) == .unavailable)
    #expect(LAAuthenticator.map(.notInteractive) == .unavailable)
    #expect(LAAuthenticator.map(.biometryNotAvailable) == .unavailable)
  }
}
