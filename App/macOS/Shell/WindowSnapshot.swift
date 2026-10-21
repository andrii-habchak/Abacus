#if DEBUG
import AppKit

/// Debug builds only: writes every visible window of the app to PNG files and quits, for UI
/// reviews without screen-recording access. Launch with
/// `-AbacusSnapshotDir <folder> -AbacusSnapshotName <prefix>` (plus `-AbacusDark YES` for dark
/// mode, `-AbacusSnapshotDelay <seconds>`).
@MainActor
enum WindowSnapshot {
  static func runIfRequested() async {
    let defaults = UserDefaults.standard
    guard let folder = defaults.string(forKey: "AbacusSnapshotDir") else { return }
    let name = defaults.string(forKey: "AbacusSnapshotName") ?? "window"
    NSApp.activate()
    let delay = defaults.double(forKey: "AbacusSnapshotDelay")
    try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2))
    capture(to: URL(filePath: folder, directoryHint: .isDirectory), prefix: name)
    NSApp.terminate(nil)
  }

  static func applyAppearance() {
    if UserDefaults.standard.bool(forKey: "AbacusDark") {
      NSApp.appearance = NSAppearance(named: .darkAqua)
    } else if UserDefaults.standard.string(forKey: "AbacusSnapshotDir") != nil {
      NSApp.appearance = NSAppearance(named: .aqua)
    }
  }

  static func capture(to folder: URL, prefix: String) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for window in NSApp.windows where window.isVisible && window.frame.width > 100 {
      guard let root = window.contentView?.superview ?? window.contentView else { continue }
      window.displayIfNeeded()
      let isMain = window.identifier?.rawValue.hasPrefix("main") == true
      let file = folder.appending(path: "\(prefix)\(isMain ? "" : "-settings").png")
      if let data = image(of: root)?.representation(using: .png, properties: [:]) {
        try? data.write(to: file)
      }
    }
  }

  /// The view drawn with `cacheDisplay`; glass panes (the sidebar) do not draw that way, so
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
