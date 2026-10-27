import Foundation

/// The colours categories, accounts and events get (R-MGMT-7, D45): distinct mid-tone hues that
/// read on light and dark backgrounds and carry a white letter (transaction tiles, account
/// tiles). Stored as `#RRGGBB`; a custom colour from the picker is any other `#RRGGBB`.
public enum ColorPalette {
  /// Palette order: the swatch order of the colour pickers.
  public static let colors: [String] = [
    "#E5484D",  // red
    "#E07B14",  // orange
    "#C99A00",  // amber
    "#7A9E1F",  // olive
    "#2E9E4F",  // green
    "#1E9E7E",  // teal
    "#0F96B0",  // cyan
    "#0A64D6",  // blue
    "#4F5BD5",  // indigo
    "#7B4FCF",  // purple
    "#B04BC4",  // magenta
    "#C93B6E",  // pink
    "#A35A2A",  // brown
    "#D4703C",  // terracotta
  ]

  /// Spoken names of `colors` (accessibility labels of the swatches), same order.
  public static let names: [String] = [
    "Red", "Orange", "Amber", "Olive", "Green", "Teal", "Cyan", "Blue", "Indigo", "Purple", "Magenta", "Pink",
    "Brown", "Terracotta",
  ]

  /// The palette name of `hex`, nil for a custom colour.
  public static func name(of hex: String?) -> String? {
    guard let key = normalized(hex), let index = colors.firstIndex(of: key) else { return nil }
    return names[index]
  }

  /// `#RRGGBB` upper-cased, or nil when `hex` is not a colour.
  public static func normalized(_ hex: String?) -> String? {
    guard let rgb = rgb(hex) else { return nil }
    return String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
  }

  /// The 0…255 channels of `#RRGGBB` (or `RRGGBB`), nil when it is not one.
  public static func rgb(_ hex: String?) -> (red: Int, green: Int, blue: Int)? {
    guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = Int(text, radix: 16) else { return nil }
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
  }

  /// No colour, not a colour, or a grey (channels within 30 of each other, e.g. `#8E8E93`):
  /// these are what the one-time fill replaces.
  public static func needsColor(_ hex: String?) -> Bool {
    guard let rgb = rgb(hex) else { return true }
    let channels = [rgb.red, rgb.green, rgb.blue]
    return (channels.max()! - channels.min()!) < 30
  }

  /// A random palette colour, preferring the ones used least among `used` (siblings, other
  /// accounts, other events), so neighbours stay apart until the palette runs out.
  public static func pick(
    avoiding used: some Sequence<String?>, using generator: inout some RandomNumberGenerator
  ) -> String {
    var counts = Dictionary(uniqueKeysWithValues: colors.map { ($0, 0) })
    for hex in used {
      if let key = normalized(hex), counts[key] != nil { counts[key, default: 0] += 1 }
    }
    let fewest = counts.values.min() ?? 0
    let candidates = colors.filter { counts[$0] == fewest }
    return candidates.randomElement(using: &generator) ?? colors[0]
  }

  public static func pick(avoiding used: [String?] = []) -> String {
    var generator = SystemRandomNumberGenerator()
    return pick(avoiding: used, using: &generator)
  }
}
