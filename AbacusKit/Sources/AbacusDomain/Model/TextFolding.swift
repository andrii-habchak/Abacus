import Foundation

/// Text folding used wherever the app compares bank text with typed text (rule matching, search,
/// duplicate hints). C42.
///
/// `String.folding(.diacriticInsensitive)` only removes *combining* marks, so it handles
/// Ą Ć Ę Ń Ó Ś Ź Ż (they decompose) but not letters that have no decomposition: Ł/ł, Ø/ø, Đ/đ,
/// ß, Æ/æ, Œ/œ, Þ/þ, Ħ/ħ, dotless ı. `fold` maps those to their usual ASCII spelling first, then
/// applies the Foundation case + diacritic folding, so "ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH" and
/// "zaklad ubezpieczen spolecznych" fold to the same text. The mapping is applied the same way
/// to patterns and to transaction text, so it is symmetric and cannot invalidate stored rules
/// (a stored "ł" pattern folds like the new "l" one).
public enum TextFolding {
  /// Letters without a Unicode decomposition → ASCII spelling.
  static let special: [Character: String] = [
    "Ł": "L", "ł": "l", "Ø": "O", "ø": "o", "Đ": "D", "đ": "d", "Ð": "D", "ð": "d",
    "ß": "ss", "ẞ": "SS", "Æ": "AE", "æ": "ae", "Œ": "OE", "œ": "oe", "Þ": "TH", "þ": "th",
    "Ħ": "H", "ħ": "h", "ı": "i", "Ŀ": "L", "ŀ": "l",
  ]

  /// The replacement character a wrongly decoded byte becomes (U+FFFD).
  public static let replacement: Character = "\u{FFFD}"

  /// Lower-cased text without diacritics; special letters spelled in ASCII. Whitespace is untouched.
  public static func fold(_ text: String) -> String {
    var mapped = ""
    mapped.reserveCapacity(text.count)
    for character in text {
      if let ascii = special[character] { mapped += ascii } else { mapped.append(character) }
    }
    return mapped.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  /// Whether `pattern` is found in `text` (both already folded) where each U+FFFD of the text
  /// (or of the pattern) matches any single character. `mode`: anywhere / at the start / the whole text.
  ///
  /// Guard against unpredictable matches: a match whose window is mostly wildcards (fewer than half
  /// of its characters are real characters) is rejected, so a text of replacement characters does not
  /// match every pattern.
  public enum Mode { case contains, prefix, exact }

  public static func matches(text: String, pattern: String, mode: Mode) -> Bool {
    guard text.contains(replacement) || pattern.contains(replacement) else {
      switch mode {
      case .contains: return text.contains(pattern)
      case .prefix: return text.hasPrefix(pattern)
      case .exact: return text == pattern
      }
    }
    let t = Array(text)
    let p = Array(pattern)
    guard !p.isEmpty, p.count <= t.count else { return false }
    if mode == .exact, p.count != t.count { return false }
    func window(at start: Int) -> Bool {
      var real = 0
      for i in p.indices {
        let a = t[start + i]
        let b = p[i]
        if a == replacement || b == replacement { continue }
        guard a == b else { return false }
        real += 1
      }
      return real * 2 >= p.count
    }
    switch mode {
    case .exact, .prefix: return window(at: 0)
    case .contains: return (0...(t.count - p.count)).contains { window(at: $0) }
    }
  }
}
