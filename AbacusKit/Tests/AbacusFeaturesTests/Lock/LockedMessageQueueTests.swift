import AbacusFeatures
import Foundation
import Testing

@MainActor
@Suite("App lock: work finishing while locked (N7, R-LOCK-12)")
struct LockedMessageQueueTests {
  func make(enabled: Bool = true) -> (AppLockModel, FakeAuthenticator) {
    let name = "lock-queue-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = LockSettingsStore(defaults: defaults)
    store.enabled = enabled
    let auth = FakeAuthenticator()
    return (AppLockModel(store: store, authenticator: auth, clock: FakeClock()), auth)
  }

  /// Lets the automatic prompt that a lock starts finish (cancelled) before the test unlocks.
  func lockAndSettle(_ model: AppLockModel, _ auth: FakeAuthenticator) async {
    auth.results = [.cancelled]
    model.lockNow()
    for _ in 0..<10 { await Task.yield() }
  }

  @Test("R-LOCK-12: unlocked, a message is shown at once")
  func unlockedShowsAtOnce() {
    let (model, _) = make(enabled: false)
    var shown: [String] = []
    model.whenUnlocked { shown.append("import done") }
    #expect(shown == ["import done"])
    #expect(model.queuedCount == 0)
  }

  @Test("R-LOCK-12: locked, messages wait and appear in order after unlock, once")
  func lockedQueuesUntilUnlock() async {
    let (model, auth) = make()
    #expect(model.isLocked)
    var shown: [String] = []
    model.whenUnlocked { shown.append("first") }
    model.whenUnlocked { shown.append("second") }
    #expect(shown.isEmpty)
    #expect(model.queuedCount == 2)

    auth.results = [.cancelled]
    await model.unlock()
    #expect(model.state == .cancelled)
    #expect(shown.isEmpty)  // a cancelled prompt delivers nothing

    auth.results = [.success]
    await model.unlock()
    #expect(shown == ["first", "second"])
    #expect(model.queuedCount == 0)

    await lockAndSettle(model, auth)
    auth.results = [.success]
    await model.unlock()
    #expect(shown == ["first", "second"])  // delivered once
  }

  @Test("R-LOCK-12: a long task keeps running while locked; its result waits for unlock")
  func longTaskRunsWhileLocked() async {
    let (model, auth) = make()
    auth.results = [.success]
    await model.unlock()
    var finished = false
    var shown: [String] = []
    let gate = AsyncStream<Void>.makeStream()
    let task = Task { @MainActor in
      for await _ in gate.stream { break }
      finished = true
      model.whenUnlocked { shown.append("import: done") }
    }
    await lockAndSettle(model, auth)
    #expect(model.isLocked)
    gate.continuation.yield()
    await task.value
    #expect(finished)  // the lock did not stop the work
    #expect(shown.isEmpty)
    auth.results = [.success]
    await model.unlock()
    #expect(shown == ["import: done"])
  }

  @Test("R-LOCK-12: turning the lock off delivers what was waiting")
  func disableDelivers() async {
    let (model, auth) = make()
    var shown = 0
    model.whenUnlocked { shown += 1 }
    auth.results = [.success]
    await model.setEnabled(false)
    #expect(model.isLocked == false)
    #expect(shown == 1)
  }
}
