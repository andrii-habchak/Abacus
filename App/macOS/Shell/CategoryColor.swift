import AbacusDomain
import AppKit
import SwiftUI

/// The one `#RRGGBB` → colour mapping of the app (R-MGMT-7: a category has the same colour on
/// every screen). The donut, its legend, the Categories page, transaction tiles, budget and
/// event bars all draw through it; parsing is `ColorPalette.rgb` (tested in AbacusKit), the
/// colour space is sRGB, and an invalid value falls back to the same neutral grey everywhere.
enum CategoryColor {
  /// The grey of "no colour" (an invalid or missing value).
  static let neutralHex = 0x8E8E93
  static let neutral = Color(nsColor: nsColor(neutralHex))

  /// The colour of `hex`, or `fallback` when it is not `#RRGGBB` / `RRGGBB`.
  static func color(_ hex: String?, fallback: Color = neutral) -> Color {
    guard let rgb = ColorPalette.rgb(hex) else { return fallback }
    return Color(nsColor: nsColor((rgb.red << 16) | (rgb.green << 8) | rgb.blue))
  }

  /// An sRGB colour from `0xRRGGBB`.
  static func nsColor(_ rgb: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}
