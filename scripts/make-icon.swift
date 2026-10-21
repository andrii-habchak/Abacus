// Draws the Abacus app icon (App/macOS/Assets.xcassets/AppIcon.appiconset).
// Usage: swift scripts/make-icon.swift App/macOS/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

// Draws the app icon on a 1024-point canvas, scaled to the requested pixel size.
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(pixels: Int) -> Data {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  ctx.setShouldAntialias(true)
  let s = CGFloat(pixels) / 1024
  ctx.scaleBy(x: s, y: s)

  // Body: macOS icon grid, 824 x 824 at (100, 100).
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

  // Drop shadow under the body.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
  ctx.addPath(bodyPath)
  ctx.setFillColor(rgb(20, 70, 66))
  ctx.fillPath()
  ctx.restoreGState()

  // Background gradient (deep teal, lighter at the top) and a soft top highlight.
  ctx.saveGState()
  ctx.addPath(bodyPath)
  ctx.clip()
  let bg = CGGradient(
    colorsSpace: space, colors: [rgb(38, 140, 128), rgb(16, 74, 82)] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
  let glow = CGGradient(
    colorsSpace: space, colors: [rgb(255, 255, 255, 0.18), rgb(255, 255, 255, 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0, endCenter: CGPoint(x: 512, y: 980),
    endRadius: 620, options: [])
  ctx.restoreGState()

  // Abacus frame.
  let frame = CGRect(x: 214, y: 254, width: 596, height: 516)
  let frameWidth: CGFloat = 34
  let framePath = CGPath(roundedRect: frame, cornerWidth: 48, cornerHeight: 48, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0, 0.3))
  ctx.addPath(framePath)
  ctx.setLineWidth(frameWidth)
  ctx.setStrokeColor(rgb(244, 232, 210))
  ctx.strokePath()
  ctx.restoreGState()

  // Rods and beads: three rows, beads pushed left and right to show a count.
  let inner = frame.insetBy(dx: frameWidth / 2, dy: frameWidth / 2)
  let rows: [(y: CGFloat, left: Int, right: Int, color: CGColor, shade: CGColor)] = [
    (inner.minY + inner.height * 0.78, 2, 3, rgb(255, 196, 77), rgb(214, 136, 22)),
    (inner.minY + inner.height * 0.50, 4, 1, rgb(255, 120, 94), rgb(206, 64, 52)),
    (inner.minY + inner.height * 0.22, 1, 4, rgb(250, 245, 235), rgb(196, 186, 168)),
  ]
  let beadW: CGFloat = 70
  let beadH: CGFloat = 92
  let gap: CGFloat = 6
  for row in rows {
    ctx.setFillColor(rgb(244, 232, 210, 0.85))
    ctx.fill(CGRect(x: inner.minX, y: row.y - 5, width: inner.width, height: 10))
    var xs: [CGFloat] = []
    for i in 0..<row.left { xs.append(inner.minX + 14 + CGFloat(i) * (beadW + gap)) }
    for i in 0..<row.right { xs.append(inner.maxX - 14 - beadW - CGFloat(i) * (beadW + gap)) }
    for x in xs {
      let rect = CGRect(x: x, y: row.y - beadH / 2, width: beadW, height: beadH)
      let bead = CGPath(ellipseIn: rect, transform: nil)
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: rgb(0, 0, 0, 0.35))
      ctx.addPath(bead)
      ctx.setFillColor(row.shade)
      ctx.fillPath()
      ctx.restoreGState()
      ctx.saveGState()
      ctx.addPath(bead)
      ctx.clip()
      let g = CGGradient(colorsSpace: space, colors: [row.color, row.shade] as CFArray, locations: [0.15, 1])!
      ctx.drawRadialGradient(
        g, startCenter: CGPoint(x: rect.midX - 10, y: rect.midY + 22), startRadius: 0,
        endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: beadH * 0.62,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      ctx.restoreGState()
    }
  }

  let image = ctx.makeImage()!
  return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let out = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
  try render(pixels: px).write(to: out.appending(path: "icon_\(px).png"))
}
print("wrote icons to \(out.path)")
