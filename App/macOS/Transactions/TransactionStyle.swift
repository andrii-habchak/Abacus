import AbacusFeatures
import AppKit
import SwiftUI

/// Colours of the transaction list (approved prototype 2), with dark-mode counterparts.
enum TxnPalette {
  static let inflow = dynamic(light: 0x1B6B3A, dark: 0x5BD08E)
  static let negative = dynamic(light: 0xB3261E, dark: 0xFF7A70)
  static let neutralTile = Color(txnHex: 0x8E8E93)
  static let barBackground = dynamic(light: 0xFAFAFC, dark: 0x262628)
  static let rule = dynamic(light: 0xECECF0, dark: 0x3A3A3D)
  static let segmentTrack = dynamic(light: 0xE8E8ED, dark: 0x3A3A3D)
  static let segmentOn = dynamic(light: 0xFFFFFF, dark: 0x636366)
  static let chipBorder = dynamic(light: 0xD2D2D7, dark: 0x4A4A4D)
  static let chipBackground = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
  static let chipActiveBorder = dynamic(light: 0x0A66D9, dark: 0x3D8BFF)
  static let chipActiveBackground = dynamic(light: 0xEAF2FD, dark: 0x13325C)
  static let chipActiveText = dynamic(light: 0x0A4FA8, dark: 0xA9CBFF)
  static let link = dynamic(light: 0x0A66D9, dark: 0x4C9BFF)

  static func badge(_ kind: TransactionListContent.Badge.Kind) -> (text: Color, fill: Color) {
    switch kind {
    case .pending: (dynamic(light: 0x8A4B00, dark: 0xFFC46B), dynamic(light: 0xFFF1D6, dark: 0x4A3410))
    case .refund: (dynamic(light: 0x1B6B3A, dark: 0x7FE0A8), dynamic(light: 0xE3F4EA, dark: 0x17402A))
    case .event: (dynamic(light: 0x5B34A8, dark: 0xCDB4FF), dynamic(light: 0xEFE8FB, dark: 0x35265A))
    case .debt: (dynamic(light: 0x0A4FA8, dark: 0xA9CBFF), dynamic(light: 0xEAF2FD, dark: 0x13325C))
    }
  }

  static func amount(_ tone: TransactionListContent.Tone) -> Color {
    switch tone {
    case .inflow: inflow
    case .outflow: .primary
    case .transfer: .secondary
    }
  }

  /// A category colour (`#RRGGBB`), grey when missing or invalid.
  static func tile(_ hex: String?) -> Color { CategoryColor.color(hex, fallback: neutralTile) }

  static func dynamic(light: Int, dark: Int) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(txnRGB: isDark ? dark : light)
      })
  }
}

extension Color {
  fileprivate init(txnHex hex: Int) {
    self.init(nsColor: NSColor(txnRGB: hex))
  }
}

extension NSColor {
  fileprivate convenience init(txnRGB rgb: Int) {
    self.init(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}

/// The four columns of the list (Description, Category, Account, Amount), sized 2.4 : 1.4 :
/// 1.2 : 1.2 of the width like the prototype grid; shared by the header, rows and nested lines.
struct TxnColumnsLayout: Layout {
  var weights: [CGFloat] = [2.4, 1.4, 1.2, 1.2]
  var spacing: CGFloat = 12

  func widths(for total: CGFloat) -> [CGFloat] {
    let available = max(0, total - spacing * CGFloat(weights.count - 1))
    let sum = weights.reduce(0, +)
    return weights.map { available * $0 / sum }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 640
    let widths = widths(for: width)
    let height = zip(subviews, widths)
      .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
      .max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    for (subview, width) in zip(subviews, widths(for: bounds.width)) {
      subview.place(
        at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
        proposal: ProposedViewSize(width: width, height: nil))
      x += width + spacing
    }
  }
}

/// Width of the category tile column and the gap after it.
enum TxnMetrics {
  static let tile: CGFloat = 26
  static let gap: CGFloat = 12
  static let horizontalPadding: CGFloat = 20
}

/// A filter chip: bordered, blue while the filter is active (prototype "chipOn").
struct TxnChipStyle: ButtonStyle {
  var isActive: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .modifier(TxnChipLook(isActive: isActive))
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(Rectangle())
  }
}

/// The chip look without the button (a chip holding its own buttons, e.g. the import filter).
struct TxnChipLook: ViewModifier {
  var isActive: Bool

  func body(content: Content) -> some View {
    content
      .font(.system(size: 13))
      .foregroundStyle(isActive ? TxnPalette.chipActiveText : Color.primary)
      .padding(.horizontal, 10)
      .frame(minHeight: 28)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isActive ? TxnPalette.chipActiveBackground : TxnPalette.chipBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(isActive ? TxnPalette.chipActiveBorder : TxnPalette.chipBorder)
      )
  }
}

/// One item of a segmented group (type toggles).
struct TxnSegmentStyle: ButtonStyle {
  var isOn: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(isOn ? Color.primary : Color.secondary)
      .padding(.horizontal, 10)
      .frame(minHeight: 24)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isOn ? TxnPalette.segmentOn : Color.clear)
          .shadow(color: .black.opacity(isOn ? 0.15 : 0), radius: 1, y: 1)
      )
      .opacity(configuration.isPressed ? 0.75 : 1)
      .contentShape(Rectangle())
  }
}

/// A row of a popover menu: checkmark column, highlighted when chosen.
struct TxnMenuItemStyle: ButtonStyle {
  var isChosen: Bool

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 14)
        .opacity(isChosen ? 1 : 0)
      configuration.label
      Spacer(minLength: 0)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 8)
    .frame(minHeight: 28)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(isChosen || configuration.isPressed ? TxnPalette.chipActiveBackground : Color.clear)
    )
    .contentShape(Rectangle())
  }
}

/// Lays its subviews out left to right at their ideal sizes and starts a new line when the next
/// one does not fit (the filter bar's chips). A subview wider than the whole row is offered the
/// row's width.
struct TxnFlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  private struct Line {
    var items: [(index: Int, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func lines(for width: CGFloat?, subviews: Subviews) -> [Line] {
    let limit = width ?? .infinity
    var lines: [Line] = []
    var line = Line()
    for (index, subview) in subviews.enumerated() {
      var size = subview.sizeThatFits(.unspecified)
      if size.width > limit {
        size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
      }
      if size.width <= 0 && size.height <= 0 { continue }
      let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
      if needed > limit, !line.items.isEmpty {
        lines.append(line)
        line = Line()
      }
      line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
      line.height = max(line.height, size.height)
      line.items.append((index, size))
    }
    if !line.items.isEmpty { lines.append(line) }
    return lines
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lines = lines(for: proposal.width, subviews: subviews)
    let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
    let width = lines.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for line in lines(for: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for item in line.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y + line.height / 2), anchor: .leading,
          proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
        x += item.size.width + spacing
      }
      y += line.height + lineSpacing
    }
  }
}
