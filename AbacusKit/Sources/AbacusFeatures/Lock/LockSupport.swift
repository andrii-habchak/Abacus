import Foundation

#if canImport(LocalAuthentication)
  import LocalAuthentication
#endif

// App lock, core contracts (N7, R-LOCK-1…4, R-LOCK-13). The lock is a UI gate: no secret, no
// Keychain, no database change.

/// Outcome of one authentication attempt.
public enum LockAuthResult: Equatable, Sendable {
  case success
  case cancelled
  case failed
  case unavailable
}

/// System authentication behind a protocol so the model never touches `LAContext` (R-LOCK-1).
@MainActor
public protocol LockAuthenticator: AnyObject {
  func authenticate(reason: String) async -> LockAuthResult
}

/// Monotonic time in seconds that keeps counting through sleep (R-LOCK-5).
public protocol LockClock: Sendable {
  var now: TimeInterval { get }
}

public struct SystemLockClock: LockClock {
  public init() {}
  public var now: TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
}

/// Why the lock engaged; `message` is shown on the lock screen.
public enum LockReason: Equatable, Sendable {
  case launch, idle(minutes: Int), sleep, screenLocked, manual

  public var message: String {
    switch self {
    case .launch: "Locked when Abacus opened."
    case .idle(let minutes): "Locked after \(Self.durationText(minutes)) idle."
    case .sleep: "Locked when the Mac went to sleep."
    case .screenLocked: "Locked when the screen locked."
    case .manual: "Locked on request."
    }
  }

  static func durationText(_ minutes: Int) -> String {
    switch minutes {
    case 1: "1 minute"
    case 60: "1 hour"
    default: "\(minutes) minutes"
    }
  }
}

/// System events that lock or unblock the prompt (R-LOCK-5 c, d).
public enum LockSystemEvent: Equatable, Sendable {
  case sleep, displaySleep, screenLocked, screenUnlocked, screensaverStarted, sessionResigned
}

/// Reports system events and user input; the model sees time and events only through this.
@MainActor
public protocol LockEventSource: AnyObject {
  var onEvent: ((LockSystemEvent) -> Void)? { get set }
  var onInput: (() -> Void)? { get set }
  func start()
  func stop()
}

/// "Lock after" choices (R-LOCK-4). Raw value = minutes, 0 = never.
public enum LockIdle: Int, CaseIterable, Identifiable, Sendable {
  case minute1 = 1, minutes5 = 5, minutes15 = 15, minutes30 = 30, hour1 = 60, never = 0

  public static let `default`: LockIdle = .minutes5
  public var id: Int { rawValue }
  public var minutes: Int? { self == .never ? nil : rawValue }
  public var title: String {
    switch self {
    case .never: "Never"
    default: LockReason.durationText(rawValue)
    }
  }
  /// Unknown stored values fall back to 5 minutes.
  public init(storedMinutes: Int?) {
    self = storedMinutes.flatMap(LockIdle.init(rawValue:)) ?? .default
  }
  /// Longer idle time weakens the lock (Never is the longest).
  var weight: Int { self == .never ? Int.max : rawValue }
  func isWeaker(than other: LockIdle) -> Bool { weight > other.weight }
}

/// Per-device lock preferences in `UserDefaults` (R-LOCK-3): never in `app_setting`, so not in
/// backups, not moved with the data folder, not synced.
public struct LockSettingsStore {
  public static let enabledKey = "appLock.enabled"
  public static let idleKey = "appLock.idleMinutes"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public var enabled: Bool {
    get { defaults.bool(forKey: Self.enabledKey) }
    nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
  }
  public var idle: LockIdle {
    get {
      LockIdle(storedMinutes: defaults.object(forKey: Self.idleKey) == nil ? nil : defaults.integer(forKey: Self.idleKey))
    }
    nonmutating set { defaults.set(newValue.rawValue, forKey: Self.idleKey) }
  }
}

#if canImport(LocalAuthentication)
  /// `.deviceOwnerAuthentication`: Touch ID / Apple Watch, else the login password. A fresh
  /// context per attempt, no reuse window, nothing stored.
  @MainActor
  public final class LAAuthenticator: LockAuthenticator {
    public init() {}

    public func authenticate(reason: String) async -> LockAuthResult {
      let context = LAContext()
      context.touchIDAuthenticationAllowableReuseDuration = 0
      var error: NSError?
      guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
      do {
        let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        return ok ? .success : .failed
      } catch let error as LAError {
        return Self.map(error.code)
      } catch {
        return .unavailable
      }
    }

    /// R-LOCK-8: cancel / failed / everything else unavailable (never unlocks).
    nonisolated public static func map(_ code: LAError.Code) -> LockAuthResult {
      switch code {
      case .userCancel, .systemCancel, .appCancel: .cancelled
      case .authenticationFailed: .failed
      default: .unavailable
      }
    }
  }
#endif
