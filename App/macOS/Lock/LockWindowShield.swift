import AbacusFeatures
import AppKit
import SwiftUI

/// Hides every attached sheet, alert, confirmation dialog and child window (popover) of the app's
/// windows while the app is locked, and puts them back exactly as they were on unlock (R-LOCK-11).
///
/// SwiftUI `.sheet`, `.alert` and `.confirmationDialog` are AppKit sheet windows attached to their
/// parent window (`NSWindow.sheets`, `sheetParent`), so the `LockGate` in the parent's content does
/// not cover them. At lock each one gets alpha 0, ignores the mouse and its content view is hidden
/// (hidden views draw nothing, get no clicks or keys and leave the accessibility tree). The
/// SwiftUI views stay mounted, so typed text and other drafts survive; nothing is dismissed.
///
/// A window with an attached sheet is modal: AppKit does not deliver clicks to it, so the lock
/// screen's buttons under a hidden sheet would be dead. While anything is hidden, a local event
/// monitor routes clicks on the lock screen's Unlock / Quit buttons (frames reported by
/// `LockView`) and Return to the model, and swallows every other key so the hidden sheet (still
/// the key window) never receives typing, Return or ⌘-shortcuts. ⌘Q, ⌘H and ⌘M still work.
@MainActor
final class LockWindowShield {
  private struct Hidden {
    weak var window: NSWindow?
    let alpha: CGFloat
    let ignoresMouse: Bool
    let contentWasHidden: Bool
    weak var responder: NSResponder?
  }

  private let model: AppLockModel
  private var hidden: [ObjectIdentifier: Hidden] = [:]
  /// Titles of top-level windows replaced by "Abacus" while locked (R-LOCK-9).
  private var titles: [ObjectIdentifier: (window: Weak, title: String)] = [:]
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []

  init(model: AppLockModel) {
    self.model = model
    let center = NotificationCenter.default
    // A sheet (or an alert from background work) that opens while locked is hidden at once.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification, NSWindow.willBeginSheetNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.refresh() }
        })
    }
    observe()
  }

  /// Re-runs `sync` whenever `isLocked` changes.
  private func observe() {
    withObservationTracking {
      _ = model.isLocked
      _ = model.enabled
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.refresh()
        self?.observe()
      }
    }
    refresh()
  }

  /// Hides what is new while locked; restores everything once unlocked.
  func refresh() {
    guard NSApp != nil else { return }  // the controller is made before the application
    keepWindowImagesOutOfSavedState()
    if model.isLocked {
      hideAttachedWindows()
      neutralTitles()
    } else if !hidden.isEmpty || !titles.isEmpty {
      restoreAll()
    }
  }

  /// Sheets (any depth) and child windows of the app's windows.
  static func attachedWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.sheetParent != nil || $0.parent != nil || $0.isSheet }
  }

  private func hideAttachedWindows() {
    for window in Self.attachedWindows() where hidden[ObjectIdentifier(window)] == nil {
      var responder = window.firstResponder
      // A text field being edited answers through the shared field editor; remember the field.
      if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
        responder = field
      }
      hidden[ObjectIdentifier(window)] = Hidden(
        window: window, alpha: window.alphaValue, ignoresMouse: window.ignoresMouseEvents,
        contentWasHidden: window.contentView?.isHidden ?? false, responder: responder)
      window.alphaValue = 0
      window.ignoresMouseEvents = true
      window.contentView?.isHidden = true
    }
    if !hidden.isEmpty, monitor == nil { installMonitor() }
  }

  /// macOS keeps window state, including window images (`window_N.data`, hundreds of KB), in
  /// Saved Application State, readable outside the lock. With the lock on, top-level windows are not
  /// restorable, so no image of unlocked content is stored (R-LOCK-9, spec Q11).
  private func keepWindowImagesOutOfSavedState() {
    let restorable = !model.enabled
    for window in NSApp.windows where window.sheetParent == nil && window.parent == nil {
      if window.isRestorable != restorable { window.isRestorable = restorable }
    }
  }

  /// The section name in the title bar becomes "Abacus" (Window menu, Mission Control).
  private func neutralTitles() {
    for window in NSApp.windows where window.sheetParent == nil && window.parent == nil && window.isVisible {
      guard window.title != "Abacus", !window.title.isEmpty else { continue }
      if titles[ObjectIdentifier(window)] == nil {
        titles[ObjectIdentifier(window)] = (Weak(window), window.title)
      }
      window.title = "Abacus"
    }
  }

  private func restoreAll() {
    for entry in titles.values { entry.window.window?.title = entry.title }
    titles.removeAll()
    let entries = hidden.values
    hidden.removeAll()
    for entry in entries {
      guard let window = entry.window else { continue }
      window.contentView?.isHidden = entry.contentWasHidden
      window.ignoresMouseEvents = entry.ignoresMouse
      window.alphaValue = entry.alpha
      if let view = entry.responder as? NSView, view.window === window {
        window.makeFirstResponder(view)
      }
    }
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  /// How many windows the shield hides now (debug log of the lock test plan).
  var hiddenCount: Int { hidden.values.filter { $0.window != nil }.count }

  // MARK: Input while sheets are hidden

  private func installMonitor() {
    let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
    monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      // Local monitors run on the main thread.
      nonisolated(unsafe) let incoming = event
      nonisolated(unsafe) var result: NSEvent? = incoming
      MainActor.assumeIsolated {
        guard let self else { return }
        result = self.filter(incoming)
      }
      return result
    }
  }

  private func filter(_ event: NSEvent) -> NSEvent? {
    guard model.isLocked, !hidden.isEmpty else { return event }
    switch event.type {
    case .keyDown, .keyUp:
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
      if flags.contains(.command), ["q", "h", "m"].contains(key) { return event }
      // Return / Enter / Space: the lock screen's default action.
      if event.type == .keyDown, [36, 76, 49].contains(event.keyCode), !event.isARepeat {
        startUnlock()
      }
      return nil
    case .leftMouseDown:
      switch LockButtonFrames.shared.button(at: event) {
      case .unlock: startUnlock()
      case .quit: NSApp.terminate(nil)
      case nil:
        // Title bar clicks still move the window; the rest of a locked window is inert.
        if let window = event.window, window.sheetParent == nil, isInTitleBar(event, of: window) { return event }
      }
      return nil
    case .leftMouseUp:
      return event.window.map { isInTitleBar(event, of: $0) } == true ? event : nil
    default:
      return nil
    }
  }

  private func isInTitleBar(_ event: NSEvent, of window: NSWindow) -> Bool {
    event.locationInWindow.y > window.contentLayoutRect.maxY
  }

  private func startUnlock() {
    guard model.state != .prompting else { return }
    Task { await model.unlock() }
  }
}

final class Weak {
  weak var window: NSWindow?
  init(_ window: NSWindow) { self.window = window }
}

/// Where the lock screens' Unlock and Quit buttons are, so `LockWindowShield` can route clicks
/// that AppKit holds back from a window with a (hidden) sheet.
@MainActor
final class LockButtonFrames {
  static let shared = LockButtonFrames()

  enum Button { case unlock, quit }

  private struct Entry {
    weak var anchor: NSView?
    var frames: [Button: CGRect] = [:]
  }

  private var entries: [UUID: Entry] = [:]

  func setAnchor(_ anchor: NSView, for id: UUID) {
    entries[id, default: Entry()].anchor = anchor
  }

  func set(_ frame: CGRect, for button: Button, id: UUID) {
    entries[id, default: Entry()].frames[button] = frame
  }

  func remove(_ id: UUID) { entries[id] = nil }

  func button(at event: NSEvent) -> Button? {
    for entry in entries.values {
      guard let anchor = entry.anchor, let window = anchor.window, window === event.window else { continue }
      let local = anchor.convert(event.locationInWindow, from: nil)
      // The anchor spans the lock view; SwiftUI frames are top-left based.
      let point = CGPoint(x: local.x, y: anchor.isFlipped ? local.y : anchor.bounds.height - local.y)
      for (button, frame) in entry.frames where frame.contains(point) { return button }
    }
    return nil
  }
}

/// A plain view behind the lock screen that reports itself as the coordinate anchor.
struct LockAnchorView: NSViewRepresentable {
  let id: UUID

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    LockButtonFrames.shared.setAnchor(view, for: id)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    LockButtonFrames.shared.setAnchor(view, for: id)
  }
}
