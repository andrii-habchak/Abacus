#if canImport(AppKit)
  import AppKit

  /// Sleep, display sleep, screen lock, screensaver, session switch and user input (R-LOCK-5).
  /// Screen lock / screensaver use long-used but undocumented distributed notifications.
  @MainActor
  public final class SystemLockEventSource: LockEventSource {
    public var onEvent: ((LockSystemEvent) -> Void)?
    public var onInput: (() -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var monitor: Any?

    public init() {}

    public func start() {
      guard tokens.isEmpty else { return }
      let workspace = NSWorkspace.shared.notificationCenter
      let distributed = DistributedNotificationCenter.default()
      let map: [(NotificationCenter, Notification.Name, LockSystemEvent)] = [
        (workspace, NSWorkspace.willSleepNotification, .sleep),
        (workspace, NSWorkspace.screensDidSleepNotification, .displaySleep),
        (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
        (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .screenUnlocked),
        (workspace, NSWorkspace.didWakeNotification, .screenUnlocked),
        (distributed, .init("com.apple.screenIsLocked"), .screenLocked),
        (distributed, .init("com.apple.screenIsUnlocked"), .screenUnlocked),
        (distributed, .init("com.apple.screensaver.didstart"), .screensaverStarted),
      ]
      for (center, name, event) in map {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.onEvent?(event) }
        }
        tokens.append((center, token))
      }
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
      ) { [weak self] event in
        MainActor.assumeIsolated { self?.onInput?() }
        return event
      }
    }

    public func stop() {
      for (center, token) in tokens { center.removeObserver(token) }
      tokens = []
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
#endif
