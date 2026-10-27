import Foundation

/// The built-in "Uncategorised" entry (D47, R-MGMT-8): not a category row but the name and
/// colour every screen uses for transactions without a category — the list, the donut, the
/// category filter, event bars. Its colour is a setting (`SettingKey.uncategorisedColor`).
/// Imported categories that happen to be named "Uncategorised …" are ordinary categories.
public enum Uncategorised {
  /// The one spelling, everywhere.
  public static let title = "Uncategorised"
  /// Amber: a clearly visible palette colour (not the grey of "no colour").
  public static let defaultColorHex = "#C99A00"

  /// The stored setting as `#RRGGBB`, or the default when unset or not a colour.
  public static func colorHex(setting: String?) -> String {
    ColorPalette.normalized(setting) ?? defaultColorHex
  }
}

extension SettingsRepository {
  /// The colour of the built-in "Uncategorised" entry (D47).
  public func uncategorisedColor() async -> String {
    Uncategorised.colorHex(setting: (try? await value(.uncategorisedColor)) ?? nil)
  }
}
