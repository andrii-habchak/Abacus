import AppKit
import SwiftUI

/// Colours of the editor sheet (approved prototype 3), with dark-mode counterparts.
enum EditorPalette {
  static let header = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
  static let body = dynamic(light: 0xF6F6F8, dark: 0x232325)
  static let rule = dynamic(light: 0xE5E5EA, dark: 0x3A3A3D)
  static let label = dynamic(light: 0x3A3A3C, dark: 0xC7C7CC)
  static let inflow = dynamic(light: 0x1B6B3A, dark: 0x5BD08E)
  static let error = dynamic(light: 0xB3001B, dark: 0xFF6B6B)
  static let suggestion = dynamic(light: 0x0A4FA8, dark: 0x8AB8FF)
  static let event = dynamic(light: 0x5B34A8, dark: 0xCDB4FF)
  static let summary = dynamic(light: 0xEEF1F6, dark: 0x2A2F38)
  static let lineBackground = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
  static let deleteBorder = dynamic(light: 0xE8B4BA, dark: 0x7A3A42)

  static func dynamic(light: Int, dark: Int) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb = isDark ? dark : light
        return NSColor(
          srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
          blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
      })
  }
}

enum EditorMetrics {
  static let width: CGFloat = 560
  static let labelColumn: CGFloat = 130
  static let maxBodyHeight: CGFloat = 620
}

/// A right-aligned form label in the 130 pt column.
struct EditorLabel: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .foregroundStyle(EditorPalette.label)
      .frame(width: EditorMetrics.labelColumn, alignment: .trailing)
  }
}

/// A small hint under a field.
struct EditorHint: View {
  let text: String
  var color: Color = .secondary

  var body: some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A 1 pt separator in the sheet's rule colour.
struct EditorRule: View {
  var body: some View {
    Rectangle()
      .fill(EditorPalette.rule)
      .frame(height: 1)
  }
}
