import AbacusFeatures
import AppKit
import SwiftUI

/// Owns the app lock for the process: the model, the system event source and the idle timer
/// (R-LOCK-5, R-LOCK-13). Independent of the database session.
@MainActor
@Observable
final class LockController {
  let model: AppLockModel
  private let source = SystemLockEventSource()
  private var shield: LockWindowShield?
  private var timer: Task<Void, Never>?

  init(previewData: Bool, lockTest: Bool) {
    if lockTest {
      // `-AbacusLockTest YES`: lock on, scripted authenticator, scratch preferences (R-LOCK-13).
      let store = LockSettingsStore(defaults: Self.scratchDefaults("abacus.lock.test"))
      store.enabled = true
      let authenticator = ScriptedAuthenticator()
      model = AppLockModel(store: store, authenticator: authenticator)
      #if DEBUG
        if let plan = UserDefaults.standard.string(forKey: "AbacusLockTestPlan") {
          authenticator.planned = true
          runPlan(plan, authenticator: authenticator)
        }
      #endif
    } else if previewData {
      // Previews and screenshots never lock or prompt.
      let store = LockSettingsStore(defaults: Self.scratchDefaults("abacus.lock.preview"))
      model = AppLockModel(store: store, authenticator: LAAuthenticator())
    } else {
      model = AppLockModel(store: LockSettingsStore(), authenticator: LAAuthenticator())
    }
    start()
  }

  /// A throwaway preferences suite; its file in ~/Library/Preferences is removed at quit.
  private static func scratchDefaults(_ prefix: String) -> UserDefaults {
    let name = "\(prefix).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in
      defaults.removePersistentDomain(forName: name)
      // The account's real home: suites ignore CFFIXED_USER_HOME.
      if let home = getpwuid(getuid())?.pointee.pw_dir {
        let file = URL(filePath: String(cString: home)).appending(path: "Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
      }
    }
    return defaults
  }

  private func start() {
    shield = LockWindowShield(model: model)
    source.onEvent = { [model] in model.handle($0) }
    source.onInput = { [model] in model.noteInput() }
    source.start()
    let center = NotificationCenter.default
    center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
      [model] _ in MainActor.assumeIsolated { model.appDidBecomeActive() }
    }
    center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
      [model] _ in MainActor.assumeIsolated { model.appDidResignActive() }
    }
    timer = Task { @MainActor [model] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        model.tick()
      }
    }
    // First prompt once the app is up and active.
    Task { @MainActor [model] in
      try? await Task.sleep(for: .milliseconds(300))
      if NSApp.isActive { model.appDidBecomeActive() }
    }
  }
}

/// Cancels the first prompt, then succeeds; for `-AbacusLockTest` screenshots. With a test plan
/// every prompt is cancelled except the plan's own unlock steps.
@MainActor
final class ScriptedAuthenticator: LockAuthenticator {
  private var count = 0
  var planned = false
  var allowNext = false
  func authenticate(reason: String) async -> LockAuthResult {
    count += 1
    try? await Task.sleep(for: .milliseconds(400))
    if planned {
      defer { allowNext = false }
      return allowNext ? .success : .cancelled
    }
    return count == 1 ? .cancelled : .success
  }
}

#if DEBUG
  extension LockController {
    /// `-AbacusLockTestPlan "2:unlock,4:lock"` (DEBUG, with `-AbacusLockTest YES`): unlocks or
    /// locks at the given seconds after launch, to check sheet hiding with the in-app snapshot.
    fileprivate func runPlan(_ plan: String, authenticator: ScriptedAuthenticator) {
      let steps = plan.split(separator: ",").compactMap { step -> (Double, String)? in
        let parts = step.split(separator: ":")
        guard parts.count == 2, let at = Double(parts[0]) else { return nil }
        return (at, String(parts[1]))
      }
      Task { @MainActor [model] in
        var elapsed = 0.0
        for (at, action) in steps {
          try? await Task.sleep(for: .seconds(max(0, at - elapsed)))
          elapsed = at
          switch action {
          case "unlock":
            authenticator.allowNext = true
            await model.unlock()
          case "lock": model.lockNow()
          default: break
          }
          // The shield applies the new state on its observation callback, a run-loop turn
          // later; apply it now so the log reports what the screen shows (QA-N L3).
          shield?.refresh()
          await Task.yield()
          let sheets = NSApp.windows.filter { $0.sheetParent != nil || $0.parent != nil }.map {
            "\(type(of: $0)) [\(Bundle(for: type(of: $0)).bundleIdentifier ?? "?")] ours \(LockWindowShield.isOurs($0)) alpha \($0.alphaValue)"
          }
          let titles = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }.map(\.title)
          let restorable = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }.map(\.isRestorable)
          NSLog(
            "LockTestPlan %@s %@: locked %d, hidden %d, attached %@, titles %@, restorable %@", "\(at)", action,
            model.isLocked ? 1 : 0, shield?.hiddenCount ?? 0, "\(sheets)", "\(titles)", "\(restorable)")
        }
      }
    }
  }
#endif

/// The opaque lock screen that covers a window (approved prototype N7, R-LOCK-7).
struct LockView: View {
  let model: AppLockModel
  /// Identifies this lock screen's button frames for `LockWindowShield`.
  @State private var frameID = UUID()

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "lock.fill")
        .font(.system(size: 44))
        .foregroundStyle(.secondary)
      Text("Abacus is locked").font(.title2.weight(.semibold))
      Text(model.reason.message).foregroundStyle(.secondary)
      if let note = stateNote {
        Text(note.text)
          .font(.callout)
          .foregroundStyle(note.color)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(note.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
          .frame(maxWidth: 380)
      }
      HStack {
        Button(model.state == .prompting ? "Waiting for Touch ID or password…" : buttonTitle) {
          Task { await model.unlock() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.state == .prompting)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
          LockButtonFrames.shared.set($0, for: .unlock, id: frameID)
        }
        Button("Quit Abacus") { NSApp.terminate(nil) }
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
            LockButtonFrames.shared.set($0, for: .quit, id: frameID)
          }
      }
      .padding(.top, 6)
      Text("Unlock uses Touch ID, Apple Watch or your Mac password.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LockAnchorView(id: frameID))
    .coordinateSpace(.named(Self.space))
    .background(Color(nsColor: .windowBackgroundColor))
    .onDisappear { LockButtonFrames.shared.remove(frameID) }
  }

  private static let space = "abacus.lockView"

  private var buttonTitle: String { model.state == .unavailable ? "Try again" : "Unlock" }

  private var stateNote: (text: String, color: Color)? {
    switch model.state {
    case .cancelled: ("Unlock was cancelled. Click Unlock to try again.", .secondary)
    case .failed: ("That didn't work. Try again, or use your Mac password.", .red)
    case .unavailable:
      (
        "Authentication isn't available right now. Check that your Mac has a login password set, then try again. Abacus stays locked until it works.",
        .orange
      )
    default: nil
    }
  }
}

/// Covers `content` while locked: content stays mounted (state, sheets' drafts kept) but is
/// invisible, inert and hidden from accessibility (R-LOCK-9).
struct LockGate<Content: View>: View {
  let model: AppLockModel
  @ViewBuilder let content: () -> Content

  var body: some View {
    ZStack {
      content()
        .opacity(model.isLocked ? 0 : 1)
        .disabled(model.isLocked)
        .allowsHitTesting(!model.isLocked)
        .accessibilityHidden(model.isLocked)
        // Section title, currency pills and "New transaction" live in the window toolbar.
        .toolbarVisibility(model.isLocked ? .hidden : .automatic, for: .windowToolbar)
      if model.isLocked {
        LockView(model: model)
      }
    }
  }
}
