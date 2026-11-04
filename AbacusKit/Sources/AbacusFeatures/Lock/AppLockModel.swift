import Foundation
import Observation

public enum LockState: Equatable, Sendable {
  case unlocked, locked, prompting, cancelled, failed, unavailable
}

/// App-level lock state machine (N7, R-LOCK-5…8, R-LOCK-13). Independent of the database.
@MainActor
@Observable
public final class AppLockModel {
  public private(set) var state: LockState = .unlocked
  public private(set) var reason: LockReason = .launch
  /// Amber banner in Settings after a cancelled / failed / unavailable change (R-LOCK-2).
  public private(set) var settingsMessage: String?
  public private(set) var enabled: Bool
  public private(set) var idle: LockIdle

  public var isLocked: Bool { state != .unlocked }
  /// Menu items that act on data are disabled while locked (R-LOCK-9).
  public var commandsEnabled: Bool { !isLocked }

  /// Deadline of the idle lock on the monotonic clock, nil when off.
  public var idleDeadline: TimeInterval? {
    guard enabled, !isLocked, let minutes = idle.minutes else { return nil }
    return lastInput + TimeInterval(minutes * 60)
  }

  private let store: LockSettingsStore
  private let authenticator: LockAuthenticator
  private let clock: LockClock
  private var lastInput: TimeInterval
  private var generation = 0
  private var isActive = true
  private var screenAvailable = true
  private var promptedThisActivation = false

  public init(store: LockSettingsStore, authenticator: LockAuthenticator, clock: LockClock = SystemLockClock()) {
    self.store = store
    self.authenticator = authenticator
    self.clock = clock
    enabled = store.enabled
    idle = store.idle
    lastInput = clock.now
    if enabled {
      state = .locked
      reason = .launch
    }
  }

  // MARK: Triggers

  public func lock(_ why: LockReason) {
    guard enabled else { return }
    if state == .prompting {
      generation += 1  // cancel the open prompt (edge case 1)
    } else if isLocked {
      return  // idempotent
    }
    reason = why
    state = .locked
    promptedThisActivation = false
    promptAutomatically()
  }

  public func lockNow() { lock(.manual) }

  public func noteInput() { lastInput = clock.now }

  /// Called by a timer and on activation; locks when the deadline has passed.
  public func tick() {
    guard let deadline = idleDeadline, clock.now >= deadline, let minutes = idle.minutes else { return }
    lock(.idle(minutes: minutes))
  }

  public func handle(_ event: LockSystemEvent) {
    switch event {
    case .sleep, .displaySleep:
      screenAvailable = false
      lock(.sleep)
    case .screenLocked, .screensaverStarted, .sessionResigned:
      screenAvailable = false
      lock(.screenLocked)
    case .screenUnlocked:
      screenAvailable = true
      tick()
      promptAutomatically()
    }
  }

  public func appDidBecomeActive() {
    isActive = true
    promptedThisActivation = false
    tick()
    promptAutomatically()
  }

  public func appDidResignActive() { isActive = false }

  // MARK: Unlock

  /// The Unlock / Try again button: always prompts.
  public func unlock() async {
    guard isLocked, state != .prompting else { return }
    await runPrompt()
  }

  private func promptAutomatically() {
    guard isLocked, state != .prompting, isActive, screenAvailable, !promptedThisActivation else { return }
    promptedThisActivation = true
    Task { await runPrompt() }
  }

  private func runPrompt() async {
    generation += 1
    let mine = generation
    state = .prompting
    let result = await authenticator.authenticate(reason: "Unlock Abacus")
    guard mine == generation, state == .prompting else { return }  // superseded by a new lock
    switch result {
    case .success:
      state = .unlocked
      lastInput = clock.now
    case .cancelled: state = .cancelled
    case .failed: state = .failed
    case .unavailable: state = .unavailable
    }
  }

  // MARK: Settings (R-LOCK-2, R-LOCK-6)

  public func clearSettingsMessage() { settingsMessage = nil }

  /// Turning on proves it works first; the window stays unlocked. Turning off needs it too.
  public func setEnabled(_ on: Bool) async {
    guard on != enabled else { return }
    let result = await authenticator.authenticate(reason: on ? "Turn on the Abacus lock" : "Turn off the Abacus lock")
    guard result == .success else {
      settingsMessage = Self.message(for: result, turningOn: on)
      return
    }
    settingsMessage = nil
    enabled = on
    store.enabled = on
    if on { lastInput = clock.now } else { state = .unlocked }
  }

  /// Increasing the idle time needs authentication; decreasing does not.
  public func setIdle(_ value: LockIdle) async {
    guard value != idle else { return }
    if value.isWeaker(than: idle), enabled {
      let result = await authenticator.authenticate(reason: "Change the Abacus lock time")
      guard result == .success else {
        settingsMessage = Self.message(for: result, turningOn: false)
        return
      }
    }
    settingsMessage = nil
    idle = value
    store.idle = value
  }

  static func message(for result: LockAuthResult, turningOn: Bool) -> String {
    let what = turningOn ? "The lock was not turned on." : "The lock setting was not changed."
    switch result {
    case .success: return ""
    case .cancelled: return "Authentication was cancelled. \(what)"
    case .failed: return "That didn't work. \(what)"
    case .unavailable: return "Authentication isn't available right now. \(what)"
    }
  }
}
