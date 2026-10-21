import AbacusDomain
import AbacusFeatures
import AppKit
import SwiftUI

/// Colours of the management screens (approved prototype group 4), with dark-mode counterparts.
enum ManagePalette {
  static let inspectorBackground = dynamic(light: 0xFAFAFC, dark: 0x232325)
  static let card = Color(nsColor: .controlBackgroundColor)
  static let border = dynamic(light: 0xE5E5EA, dark: 0x3A3A3D)
  static let headerBackground = dynamic(light: 0xFAFAFC, dark: 0x262628)
  static let barTrack = dynamic(light: 0xEBEBF0, dark: 0x3A3A3D)
  static let negative = dynamic(light: 0xB3261E, dark: 0xFF7A70)
  static let destructive = dynamic(light: 0xB3001B, dark: 0xFF6B6B)
  static let asset = dynamic(light: 0x0A66D9, dark: 0x2F7FE6)
  static let liability = dynamic(light: 0xB3261E, dark: 0xD9483F)
  static let match = dynamic(light: 0xEAF2FD, dark: 0x173052)
  static let matchText = dynamic(light: 0x0A4FA8, dark: 0xA9CBFF)
  static let badge = dynamic(light: 0xEBEBF0, dark: 0x3A3A3D)
  static let grip = dynamic(light: 0xB0B0B5, dark: 0x6E6E73)
  static let link = dynamic(light: 0x0A66D9, dark: 0x4C9BFF)

  static func status(_ status: LimitStatus?) -> Color {
    switch status {
    case .over: negative
    case .near: .orange
    case .ok, nil: .secondary
    }
  }

  /// A category colour (`#RRGGBB`), grey when missing or invalid.
  static func hex(_ hex: String?) -> Color {
    guard let hex, hex.hasPrefix("#"), let value = Int(hex.dropFirst(), radix: 16) else {
      return Color(nsColor: NSColor(manageRGB: 0x8E8E93))
    }
    return Color(nsColor: NSColor(manageRGB: value))
  }

  static func dynamic(light: Int, dark: Int) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(manageRGB: isDark ? dark : light)
      })
  }
}

extension NSColor {
  fileprivate convenience init(manageRGB rgb: Int) {
    self.init(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}

/// Width of the inspector column next to a list.
enum ManageMetrics {
  static let inspectorWidth: CGFloat = 320
  static let horizontalPadding: CGFloat = 20
}

/// The right-hand inspector: a titled column of fields on the light-grey panel.
struct ManageInspector<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(2)
          .accessibilityAddTraits(.isHeader)
        content
      }
      .font(.system(size: 13))
      .padding(.horizontal, 20)
      .padding(.vertical, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: ManageMetrics.inspectorWidth)
    .frame(maxHeight: .infinity)
    .background(ManagePalette.inspectorBackground)
  }
}

/// A field with its label above it, as in the prototype's inspectors.
struct ManageField<Content: View>: View {
  let label: String
  @ViewBuilder var content: Content

  init(_ label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).foregroundStyle(.secondary)
      content
    }
  }
}

/// A white rounded box (current balance, usage, spent).
struct ManageCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) { content }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ManagePalette.card, in: .rect(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ManagePalette.border))
  }
}

/// "Revert" + "Save" under an inspector form while it has unsaved edits; the validation
/// problem and a failure message above them.
struct ManageSaveBar: View {
  let isNew: Bool
  let isDirty: Bool
  let canSave: Bool
  let validation: String?
  let error: String?
  let onRevert: () -> Void
  let onSave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if isDirty, let validation {
        Text(validation).font(.caption).foregroundStyle(ManagePalette.negative)
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(ManagePalette.negative)
      }
      if isDirty {
        HStack(spacing: 8) {
          Button(isNew ? "Cancel" : "Revert", action: onRevert)
          Button(isNew ? "Create" : "Save changes", action: onSave)
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .keyboardShortcut("s", modifiers: .command)
        }
      }
    }
  }
}

/// A thin horizontal bar (share of the budget, spent by category).
struct ManageBar: View {
  let fraction: Double
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(ManagePalette.barTrack)
        Capsule().fill(color).frame(width: proxy.size.width * min(1, max(0, fraction)))
      }
    }
    .frame(height: 6)
    .accessibilityHidden(true)
  }
}

/// A category colour dot.
struct ManageDot: View {
  let hex: String?
  var size: CGFloat = 10

  var body: some View {
    Circle().fill(ManagePalette.hex(hex)).frame(width: size, height: size).accessibilityHidden(true)
  }
}

/// The six-dot drag handle of a reorderable row.
struct ManageGrip: View {
  var body: some View {
    VStack(spacing: 2.4) {
      ForEach(0..<3, id: \.self) { _ in
        HStack(spacing: 2.4) {
          Circle().frame(width: 2.4, height: 2.4)
          Circle().frame(width: 2.4, height: 2.4)
        }
      }
    }
    .foregroundStyle(ManagePalette.grip)
    .frame(width: 10, height: 14)
    .accessibilityHidden(true)
  }
}

/// The confirmation dialog of the management screens (prototype "alertdialog"): title, message,
/// optional reassignment picker, "Archive instead", Cancel and the confirm button.
struct ManageDialogView: View {
  let dialog: ManageDialog
  var target: Binding<AbacusDomain.Category.ID?>? = nil
  var canConfirm = true
  var onArchiveInstead: (() -> Void)? = nil
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(dialog.title)
        .font(.system(size: 15, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(dialog.message)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .lineSpacing(2)
      if dialog.needsTarget, let target {
        ManageField("Move its transactions and budget limit to") {
          Picker("Move its transactions and budget limit to", selection: target) {
            ForEach(dialog.targets) { option in
              Text(option.isChild ? "    \(option.name)" : option.name).tag(Optional(option.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      HStack(spacing: 8) {
        if dialog.offersArchive, let onArchiveInstead {
          Button("Archive instead", action: onArchiveInstead)
        }
        Spacer(minLength: 0)
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(dialog.confirmTitle, role: dialog.isDestructive ? .destructive : nil, action: onConfirm)
          .buttonStyle(.borderedProminent)
          .tint(dialog.isDestructive ? ManagePalette.destructive : .accentColor)
          .keyboardShortcut(.defaultAction)
          .disabled(!canConfirm)
      }
      .padding(.top, 4)
    }
    .font(.system(size: 13))
    .padding(20)
    .frame(width: 420)
  }
}

/// A non-blocking message line (load failure, missing rates).
struct ManageNotice: View {
  let text: String
  var systemImage = "exclamationmark.triangle.fill"

  var body: some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(.orange)
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 8))
  }
}

/// Loading / failure / content switch shared by the five screens.
struct ManagePhaseView<Content: View>: View {
  let phase: ManagePhase
  let title: String
  let retry: () async -> Void
  @ViewBuilder var content: Content

  var body: some View {
    switch phase {
    case .failed(let message):
      ContentUnavailableView {
        Label("\(title) unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Try again") { Task { await retry() } }
      }
    case .idle, .loading:
      ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      content
    }
  }
}

/// A binding into an optional draft held by a model: reads `fallback` while there is no draft,
/// writes only when there is one.
@MainActor
func draftBinding<Root, Value>(
  _ get: @escaping () -> Root?, _ set: @escaping (Root) -> Void, _ keyPath: WritableKeyPath<Root, Value>,
  fallback: Value
) -> Binding<Value> {
  Binding(
    get: { get()?[keyPath: keyPath] ?? fallback },
    set: { value in
      guard var root = get() else { return }
      root[keyPath: keyPath] = value
      set(root)
    })
}

/// Columns like a CSS grid template: fixed widths and fractions of what is left
/// (`[.flex(2), .fixed(140), .flex(1), .fixed(36)]` = "2fr 140px 1fr 36px"). Children are placed
/// left to right, vertically centred.
struct ManageColumns: Layout {
  enum Column {
    case fixed(CGFloat)
    case flex(CGFloat)
  }

  var columns: [Column]
  var spacing: CGFloat = 10

  func widths(for total: CGFloat) -> [CGFloat] {
    var fixed: CGFloat = 0
    var fractions: CGFloat = 0
    for column in columns {
      switch column {
      case .fixed(let width): fixed += width
      case .flex(let weight): fractions += weight
      }
    }
    let available = max(0, total - fixed - spacing * CGFloat(max(0, columns.count - 1)))
    return columns.map { column in
      switch column {
      case .fixed(let width): width
      case .flex(let weight): fractions > 0 ? available * weight / fractions : 0
      }
    }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 640
    let height = zip(subviews, widths(for: width))
      .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
      .max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    for (subview, width) in zip(subviews, widths(for: bounds.width)) {
      subview.place(
        at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: nil))
      x += width + spacing
    }
  }
}
