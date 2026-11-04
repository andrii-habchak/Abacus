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
  private var timer: Task<Void, Never>?

  init(previewData: Bool, lockTest: Bool) {
    if lockTest {
      // `-AbacusLockTest YES`: lock on, scripted authenticator, scratch preferences (R-LOCK-13).
      let store = LockSettingsStore(defaults: UserDefaults(suiteName: "abacus.lock.test.\(UUID().uuidString)")!)
      store.enabled = true
      model = AppLockModel(store: store, authenticator: ScriptedAuthenticator())
    } else if previewData {
      // Previews and screenshots never lock or prompt.
      let store = LockSettingsStore(defaults: UserDefaults(suiteName: "abacus.lock.preview.\(UUID().uuidString)")!)
      model = AppLockModel(store: store, authenticator: LAAuthenticator())
    } else {
      model = AppLockModel(store: LockSettingsStore(), authenticator: LAAuthenticator())
    }
    start()
  }

  private func start() {
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

/// Cancels the first prompt, then succeeds; for `-AbacusLockTest` screenshots.
@MainActor
final class ScriptedAuthenticator: LockAuthenticator {
  private var count = 0
  func authenticate(reason: String) async -> LockAuthResult {
    count += 1
    try? await Task.sleep(for: .milliseconds(400))
    return count == 1 ? .cancelled : .success
  }
}

/// The opaque lock screen that covers a window (approved prototype N7, R-LOCK-7).
struct LockView: View {
  let model: AppLockModel

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
        Button("Quit Abacus") { NSApp.terminate(nil) }
      }
      .padding(.top, 6)
      Text("Unlock uses Touch ID, Apple Watch or your Mac password.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

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
      if model.isLocked {
        LockView(model: model)
      }
    }
  }
}
