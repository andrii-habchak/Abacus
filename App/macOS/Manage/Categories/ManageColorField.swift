import AbacusDomain
import AbacusFeatures
import AppKit
import SwiftUI

/// The colour of a category, account or event (R-MGMT-7): the palette swatches, plus the system
/// colour panel for a custom colour. Stored as `#RRGGBB`.
struct ManageColorField: View {
  @Binding var hex: String?

  private let columns = Array(repeating: GridItem(.fixed(24), spacing: 8), count: 7)

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
        ForEach(ManageText.swatches, id: \.self) { swatch in
          let isSelected = ColorPalette.normalized(hex) == swatch
          Button {
            hex = swatch
          } label: {
            ManageDot(hex: swatch, size: 20)
              .overlay(
                Circle()
                  .strokeBorder(ManagePalette.hex(swatch), lineWidth: 2)
                  .padding(-3)
                  .opacity(isSelected ? 1 : 0))
              .frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(ColorPalette.name(of: swatch) ?? swatch)
          .accessibilityLabel(ColorPalette.name(of: swatch) ?? swatch)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
      }
      HStack(spacing: 8) {
        ColorPicker("Custom colour", selection: custom, supportsOpacity: false)
          .font(.system(size: 12))
        if isCustom, let hex = ColorPalette.normalized(hex) {
          Text(hex)
            .font(.system(size: 11).monospaced())
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var isCustom: Bool {
    ColorPalette.normalized(hex).map { !ManageText.swatches.contains($0) } ?? false
  }

  /// The colour panel's colour as `#RRGGBB` (sRGB).
  private var custom: Binding<Color> {
    Binding(
      get: { ManagePalette.hex(hex) },
      set: { color in
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        hex = String(
          format: "#%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
      })
  }
}
