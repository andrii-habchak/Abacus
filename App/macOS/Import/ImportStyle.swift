import AbacusFeatures
import AbacusImport
import AppKit
import SwiftUI

/// Colours of the import wizard (approved prototype 5), with dark-mode counterparts.
enum ImportPalette {
  static let bar = dynamic(light: 0xFAFAFC, dark: 0x262628)
  static let surface = dynamic(light: 0xFFFFFF, dark: 0x1E1E20)
  static let rule = dynamic(light: 0xE0E0E5, dark: 0x3A3A3D)
  static let softRule = dynamic(light: 0xF3F3F6, dark: 0x2E2E31)
  static let border = dynamic(light: 0xE5E5EA, dark: 0x3A3A3D)
  static let label = dynamic(light: 0x3A3A3C, dark: 0xC7C7CC)
  static let accent = dynamic(light: 0x0A66D9, dark: 0x3D8BFF)
  static let accentText = dynamic(light: 0x0A4FA8, dark: 0xA9CBFF)
  static let accentFill = dynamic(light: 0xF2F7FE, dark: 0x13325C)
  static let inflow = dynamic(light: 0x1B6B3A, dark: 0x5BD08E)
  static let attention = dynamic(light: 0xB3001B, dark: 0xFF6B6B)
  static let attentionBorder = dynamic(light: 0xE8A0A8, dark: 0x8A3A44)
  static let dropZone = dynamic(light: 0xFAFAFC, dark: 0x232325)
  static let dropBorder = dynamic(light: 0xC7C7CC, dark: 0x55555A)
  static let reviewFill = dynamic(light: 0xFFFCF4, dark: 0x2E2817)
  static let reviewBorder = dynamic(light: 0xF0D9A8, dark: 0x6B5320)
  static let duplicateFill = dynamic(light: 0xFFFBF2, dark: 0x3A2E14)
  static let duplicateBorder = dynamic(light: 0xE0B25C, dark: 0x8A6A2A)
  static let success = dynamic(light: 0x1B8A4A, dark: 0x5BD08E)

  /// Step indicator: current, done, upcoming.
  static let stepCurrent = (text: Color.white, fill: accent)
  static let stepDone = (text: dynamic(light: 0x1B6B3A, dark: 0x7FE0A8), fill: dynamic(light: 0xE3F4EA, dark: 0x17402A))
  static let stepNext = (text: dynamic(light: 0x6E6E73, dark: 0x98989D), fill: dynamic(light: 0xEEEEF1, dark: 0x3A3A3D))

  /// Badge colours per row status (text, fill).
  static func badge(_ status: RowStatus) -> (text: Color, fill: Color) {
    switch status {
    case .new: (accentText, dynamic(light: 0xE6EEF9, dark: 0x1B3358))
    case .alreadyImported, .skipped: (dynamic(light: 0x6E6E73, dark: 0x98989D), dynamic(light: 0xEEEEF1, dark: 0x3A3A3D))
    case .possibleDuplicate: (dynamic(light: 0x8A4B00, dark: 0xFFC46B), dynamic(light: 0xFFF1D6, dark: 0x4A3410))
    case .settlesPending: (dynamic(light: 0x1B6B3A, dark: 0x7FE0A8), dynamic(light: 0xE3F4EA, dark: 0x17402A))
    case .needsReview: (dynamic(light: 0xB3001B, dark: 0xFF8A95), dynamic(light: 0xFDE7EA, dark: 0x4A1A20))
    }
  }

  /// Count colour of a summary card (nil = all rows).
  static func cardCount(_ status: RowStatus?) -> Color {
    guard let status else { return .primary }
    return switch status {
    case .new: accentText
    case .alreadyImported, .skipped: .secondary
    case .possibleDuplicate: dynamic(light: 0x8A4B00, dark: 0xFFC46B)
    case .settlesPending: inflow
    case .needsReview: attention
    }
  }

  static func tone(_ tone: ImportTone) -> Color {
    switch tone {
    case .secondary: .secondary
    case .info: accentText
    case .success: inflow
    case .attention: attention
    }
  }

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

enum ImportMetrics {
  static let horizontalPadding: CGFloat = 20
  static let historyWidth: CGFloat = 380
}

/// A note under a control, coloured by its tone.
struct ImportNoteText: View {
  let note: ImportNote

  var body: some View {
    Text(note.text)
      .font(.system(size: 11))
      .foregroundStyle(ImportPalette.tone(note.tone))
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A capsule badge ("New", "Possible duplicate", …).
struct ImportBadge: View {
  let text: String
  let colors: (text: Color, fill: Color)

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(colors.text)
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(Capsule().fill(colors.fill))
  }
}

/// A 1 pt separator.
struct ImportRule: View {
  var color: Color = ImportPalette.rule

  var body: some View {
    Rectangle().fill(color).frame(height: 1)
  }
}
