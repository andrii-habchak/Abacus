import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// C47: PKO text decoding (Windows-1250, UTF-8, mixed) and the replacement-character repair.
@Suite("PKO text encoding (C47)")
struct PKOEncodingTests {
  private let header =
    #""Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","","""#
  private let polish = "ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH NA WŁASNY KOSZT URZĄD żółć"

  private func line(_ text: String) -> String { #""\#(text)","x""# }

  @Test("pure Windows-1250 decodes every Polish letter")
  func cp1250() throws {
    let data = try #require((header + "\r\n" + line(polish) + "\r\n").data(using: .windowsCP1250))
    let text = try #require(PKOText.decode(data))
    #expect(text.contains(polish))
    #expect(!text.contains("\u{FFFD}"))
  }

  @Test("pure UTF-8 (with BOM) decodes")
  func utf8() throws {
    let data = Data(("\u{FEFF}" + header + "\r\n" + line(polish) + "\r\n").utf8)
    let text = try #require(PKOText.decode(data))
    #expect(text.hasPrefix("\"Data operacji"))
    #expect(text.contains(polish))
  }

  @Test("mixed file: Windows-1250 lines and UTF-8 lines both decode")
  func mixed() throws {
    var data = try #require((header + "\r\n" + line(polish) + "\r\n").data(using: .windowsCP1250))
    data.append(Data((line(polish) + "\r\n").utf8))
    data.append(try #require((line(polish) + "\r\n").data(using: .windowsCP1250)))
    let text = try #require(PKOText.decode(data))
    #expect(text.components(separatedBy: polish).count == 4)
    #expect(!text.contains("\u{FFFD}"))
  }

  @Test("a byte Windows-1250 leaves undefined costs only that byte, not the file")
  func undefinedByte() throws {
    var data = try #require((header + "\r\n" + line(polish) + "\r\n").data(using: .windowsCP1250))
    data.append(contentsOf: Array(#""A"#.utf8) + [0x81] + Array(#"B","x"\#r\#n"#.utf8))
    let text = try #require(PKOText.decode(data))
    #expect(text.contains(polish))
    #expect(text.contains("A\u{FFFD}B"))
  }

  @Test("a literal U+FFFD in a UTF-8 source stays as is (nothing to recover)")
  func literalReplacement() throws {
    let data = Data((header + "\r\n" + line("ZAK\u{FFFD}AD") + "\r\n").utf8)
    let text = try #require(PKOText.decode(data))
    #expect(text.contains("ZAK\u{FFFD}AD"))
  }

  @Test("bytes of a Windows-1250 file read as lossy UTF-8 give the U+FFFD pattern (root cause shape)")
  func lossyShape() throws {
    let bytes = try #require("ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH".data(using: .windowsCP1250))
    let lossy = String(decoding: bytes, as: UTF8.self)
    #expect(lossy == "ZAK\u{FFFD}AD UBEZPIECZE\u{FFFD} SPO\u{FFFD}ECZNYCH")
    // Our decoder never produces that:
    #expect(PKOText.decode(bytes) == "ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH")
  }

  @Test("an old rule pattern with U+FFFD is repaired from properly decoded text")
  func repair() {
    let pattern = "ZAK\u{FFFD}AD UBEZPIECZE\u{FFFD} SPO\u{FFFD}ECZNYCH"
    #expect(
      TextFolding.repairedPattern(pattern, in: "Przelew ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH zus")
        == "ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH")
    #expect(TextFolding.repairedPattern(pattern, in: "ZAK\u{FFFD}AD UBEZPIECZE\u{FFFD} SPO\u{FFFD}ECZNYCH") == nil)
    #expect(TextFolding.repairedPattern("plain", in: "plain text") == nil)
    #expect(TextFolding.repairedPattern("Z\u{FFFD}\u{FFFD}", in: "ZUS") == nil)
  }

  @Test("display text shows a placeholder, stored text is untouched")
  func display() {
    let stored = "ZAK\u{FFFD}AD"
    #expect(TextFolding.displayText(stored) == "ZAK\u{25AF}AD")
    #expect(TextFolding.displayText("ZAKŁAD") == "ZAKŁAD")
    #expect(TextFolding.hasUnreadable(stored))
    #expect(stored.contains("\u{FFFD}"))
  }
}
