#if DEBUG
import AbacusDomain
import AbacusFeatures
import AppKit
import ScreenCaptureKit

/// Debug builds only: writes every visible window of the app to PNG files and quits, for UI
/// reviews and README screenshots. Launch with
/// `-AbacusSnapshotDir <folder> -AbacusSnapshotName <prefix>` (plus `-AbacusDark YES` for dark
/// mode, `-AbacusSnapshotDelay <seconds>`, `-AbacusDisplayCurrency EUR` to switch the display
/// currency first, `-AbacusSnapshotFullPage YES` to grow the main window until its page scroll
/// view shows its whole document, e.g. every dashboard widget).
///
/// Windows are captured with ScreenCaptureKit (`SCShareableContent.currentProcess`: an app's own
/// windows need no Screen Recording permission), so sidebar glass, toolbar and traffic lights
/// look exactly as on screen. If that fails, the older `cacheDisplay` paint below is used.
@MainActor
enum WindowSnapshot {
  static func runIfRequested(session: AppSession) async {
    let defaults = UserDefaults.standard
    guard let folder = defaults.string(forKey: "AbacusSnapshotDir") else { return }
    let name = defaults.string(forKey: "AbacusSnapshotName") ?? "window"
    if let code = defaults.string(forKey: "AbacusDisplayCurrency"), let currency = Currency(rawValue: code) {
      // As if the app had launched with this default: the rates page follows it too.
      await session.app.setDisplayCurrency(currency).value
      session.app.rates.showIn = currency
    }
    NSApp.activate(ignoringOtherApps: true)
    // Active chrome (coloured traffic lights): the Settings window when it is open, else main.
    let settings = NSApp.windows.first { $0.isVisible && $0.frame.width > 100 && $0 !== mainWindow }
    (settings ?? mainWindow)?.makeKeyAndOrderFront(nil)
    let delay = defaults.double(forKey: "AbacusSnapshotDelay")
    try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2))
    if defaults.bool(forKey: "AbacusSnapshotFullPage") { await growToFitContent() }
    await capture(to: URL(filePath: folder, directoryHint: .isDirectory), prefix: name)
    NSApp.terminate(nil)
  }

  private static var mainWindow: NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
  }

  /// Makes the main window tall enough that its biggest vertical scroll view (the page) shows
  /// its whole document; the window may reach below the screen, which the capture still sees.
  private static func growToFitContent() async {
    guard let window = mainWindow, let root = window.contentView else { return }
    allowFramesBeyondScreen(window)
    for _ in 0..<4 {
      let scrolls = descendants(of: root).compactMap { $0 as? NSScrollView }
      guard
        let page = scrolls.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
        let document = page.documentView
      else { return }
      // The clip view runs under the toolbar; its insets are not part of the visible page.
      let insets = page.contentView.contentInsets
      let visible = page.contentView.bounds.height - insets.top - insets.bottom
      let extra = (document.frame.height - visible).rounded(.up)
      guard extra > 1 else { return }
      var frame = window.frame
      frame.size.height += extra
      frame.origin.y -= extra
      window.setFrame(frame, display: true)
      try? await Task.sleep(for: .seconds(1))
      print("WindowSnapshot: page \(document.frame.height) pt, window \(window.frame.height) pt")
    }
  }

  /// AppKit keeps a window inside the screen (`constrainFrameRect(_:to:)`); for a full-page
  /// capture the main window is moved to a runtime subclass that returns the frame unchanged.
  private static func allowFramesBeyondScreen(_ window: NSWindow) {
    let base: AnyClass = type(of: window)
    let name = "AbacusSnapshotUnconstrained_\(NSStringFromClass(base))"
    var subclass: AnyClass? = NSClassFromString(name)
    if subclass == nil, let created = objc_allocateClassPair(base, name, 0),
      let method = class_getInstanceMethod(base, #selector(NSWindow.constrainFrameRect(_:to:)))
    {
      let unconstrained: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
      class_addMethod(
        created, #selector(NSWindow.constrainFrameRect(_:to:)), imp_implementationWithBlock(unconstrained),
        method_getTypeEncoding(method))
      objc_registerClassPair(created)
      subclass = created
    }
    if let subclass { object_setClass(window, subclass) }
  }

  /// The window as the window server composites it (glass, chrome; no shadow, transparent
  /// rounded corners), at the backing scale. Nil when ScreenCaptureKit is unavailable.
  private static func screenCapture(_ window: NSWindow, in shareable: SCShareableContent?) async -> CGImage? {
    guard let target = shareable?.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
    else { return nil }
    let filter = SCContentFilter(desktopIndependentWindow: target)
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = Int((filter.contentRect.width * scale).rounded())
    configuration.height = Int((filter.contentRect.height * scale).rounded())
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.captureResolution = .best
    do {
      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    } catch {
      print("WindowSnapshot: ScreenCaptureKit failed: \(error.localizedDescription)")
      return nil
    }
  }

  static func applyAppearance() {
    if UserDefaults.standard.bool(forKey: "AbacusDark") {
      NSApp.appearance = NSAppearance(named: .darkAqua)
    } else if UserDefaults.standard.string(forKey: "AbacusSnapshotDir") != nil {
      NSApp.appearance = NSAppearance(named: .aqua)
    }
  }

  static func capture(to folder: URL, prefix: String) async {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let shareable: SCShareableContent?
    do {
      shareable = try await SCShareableContent.currentProcess
    } catch {
      print("WindowSnapshot: no shareable content: \(error.localizedDescription)")
      shareable = nil
    }
    for window in NSApp.windows where window.isVisible && window.frame.width > 100 {
      guard let root = window.contentView?.superview ?? window.contentView else { continue }
      window.displayIfNeeded()
      let isMain = window.identifier?.rawValue.hasPrefix("main") == true
      let file = folder.appending(path: "\(prefix)\(isMain ? "" : "-settings").png")
      let data: Data?
      if let shot = await screenCapture(window, in: shareable) {
        data = NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:])
      } else {
        print("WindowSnapshot: painting \(file.lastPathComponent) with cacheDisplay")
        data = image(of: root)?.representation(using: .png, properties: [:])
      }
      try? data?.write(to: file)
    }
  }

  /// Fallback: the view drawn with `cacheDisplay`; glass panes (the sidebar) do not draw that way, so
  /// they are painted over with a plain sidebar colour and their content.
  private static func image(of root: NSView) -> NSBitmapImageRep? {
    guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
    root.cacheDisplay(in: root.bounds, to: rep)
    guard
      let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else { return rep }
    out.size = rep.size
    guard let context = NSGraphicsContext(bitmapImageRep: out) else { return rep }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    rep.draw(in: root.bounds)
    let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    for glass in descendants(of: root).compactMap({ $0 as? NSGlassEffectView }) where glass.bounds.height > 200 {
      let frame = glass.convert(glass.bounds, to: root)
      (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)).setFill()
      NSBezierPath(roundedRect: frame.insetBy(dx: 8, dy: 8), xRadius: 14, yRadius: 14).fill()
      // The pane's SwiftUI content (e.g. the Settings link): multiply keeps the fill, adds ink.
      for host in descendants(of: glass) where !dark && "\(type(of: host))".hasPrefix("NSHostingView<") {
        draw(host, into: root, operation: .multiply)
      }
      // The sidebar list: vibrant selection draws black off-screen, so paint a plain one.
      for table in descendants(of: glass).compactMap({ $0 as? NSTableView }) {
        let style = table.selectionHighlightStyle
        if table.selectedRow >= 0 {
          let rect = table.convert(table.rect(ofRow: table.selectedRow), to: root).insetBy(dx: 10, dy: 1)
          (dark ? NSColor(white: 0.3, alpha: 1) : NSColor(white: 0.84, alpha: 1)).setFill()
          NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        table.selectionHighlightStyle = .none
        table.displayIfNeeded()
        draw(table, into: root, operation: .sourceOver, tint: dark ? NSColor(white: 0.9, alpha: 1) : nil)
        table.selectionHighlightStyle = style
      }
    }
    // Toolbar segmented controls: the selected segment's glass thumb does not draw either;
    // paint a plain thumb with the segment's label.
    for control in descendants(of: root).compactMap({ $0 as? NSSegmentedControl }) where control.window?.toolbar != nil {
      let selected = control.selectedSegment
      guard selected >= 0, control.convert(control.bounds, to: root).maxY > root.bounds.maxY - 60 else { continue }
      var x: CGFloat = 0
      for index in 0..<selected { x += control.width(forSegment: index) }
      let width = control.width(forSegment: selected)
      let segmentWidth = width > 0 ? width : control.bounds.width / CGFloat(control.segmentCount)
      if width <= 0 { x = segmentWidth * CGFloat(selected) }
      let rect = control.convert(
        NSRect(x: x + 2, y: 3, width: segmentWidth - 4, height: control.bounds.height - 6), to: root)
      (dark ? NSColor(white: 0.35, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
      NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
      let label = (control.label(forSegment: selected) ?? "") as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        .foregroundColor: dark ? NSColor.white : NSColor.black,
      ]
      let size = label.size(withAttributes: attributes)
      label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
    NSGraphicsContext.restoreGraphicsState()
    return out
  }

  /// Draws `view` as cached; with `tint`, its ink is recoloured (vibrant text renders black
  /// off-screen, unreadable on a dark pane).
  private static func draw(
    _ view: NSView, into root: NSView, operation: NSCompositingOperation, tint: NSColor? = nil
  ) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let target = view.convert(view.bounds, to: root)
    guard let tint else {
      rep.draw(in: target, from: .zero, operation: operation, fraction: 1, respectFlipped: true, hints: nil)
      return
    }
    let image = NSImage(size: view.bounds.size, flipped: false) { bounds in
      rep.draw(in: bounds)
      tint.setFill()
      bounds.fill(using: .sourceAtop)
      return true
    }
    image.draw(in: target, from: .zero, operation: operation, fraction: 1, respectFlipped: true, hints: nil)
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(of: $0) }
  }
}
#endif
