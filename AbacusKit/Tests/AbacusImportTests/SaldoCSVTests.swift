import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

@Suite("Saldo CSV reading")
struct SaldoCSVTests {
  private func records(_ text: String) throws -> [CSVRecord] {
    try CSVReader.records(CSVReader.strippingBOM([UInt8](text.utf8)))
  }

  @Test("R-IMP-SALDO-1: quoted fields, escaped quotes and line breaks inside quotes")
  func quotedFields() throws {
    let text = "\"a\",\"b\"\n\"1\",\"say \"\"hi\"\"\nnext line\"\n\"2\",\"\"\n"
    let result = try records(text)
    #expect(result.count == 3)
    #expect(result[1].fields == ["1", "say \"hi\"\nnext line"])
    #expect(result[1].line == 2)
    #expect(result[2].fields == ["2", ""])
    #expect(result[2].line == 4)
  }

  @Test("R-IMP-SALDO-1: UTF-8 with BOM, CRLF line ends, unquoted fields and blank lines")
  func bomAndCRLF() throws {
    let text = "\u{FEFF}\"x\",y\r\n\r\n\"Кава\",2\r\n"
    let result = try records(text)
    #expect(result.map(\.fields) == [["x", "y"], ["Кава", "2"]])
    #expect(result[1].line == 3)
  }

  @Test("R-IMP-SALDO-1: an unclosed quote is a malformed file")
  func unclosedQuote() {
    #expect(throws: ImportError.malformed(line: 2, reason: "Unclosed quote")) {
      try records("\"a\"\n\"b,c\n")
    }
  }

  @Test("R-IMP-SALDO-1: text after a closing quote is malformed")
  func textAfterQuote() {
    #expect(throws: ImportError.self) { try records("\"a\"b\n") }
  }

  @Test("R-IMP-SALDO-1: the three Transaction Date shapes are read as local time")
  func dateShapes() throws {
    let utc = SaldoFixture.utc
    let base = try #require(SaldoDate.parse("2024-06-01T12:04:15", timeZone: utc))
    #expect(base == Date(timeIntervalSince1970: 1_717_243_455))
    let millis = try #require(SaldoDate.parse("2024-06-01T12:04:15.835", timeZone: utc))
    #expect(abs(millis.timeIntervalSince(base) - 0.835) < 0.000_001)
    let minutes = try #require(SaldoDate.parse("2024-06-01T12:04", timeZone: utc))
    #expect(base.timeIntervalSince(minutes) == 15)

    let warsaw = TimeZone(identifier: "Europe/Warsaw")!
    let local = try #require(SaldoDate.parse("2024-06-01T12:04:15", timeZone: warsaw))
    #expect(base.timeIntervalSince(local) == 2 * 3600)

    #expect(SaldoDate.parse("2024-06-01 12:04:15", timeZone: utc) == nil)
    #expect(SaldoDate.parse("2024-13-01T12:04", timeZone: utc) == nil)
    #expect(SaldoDate.parse("", timeZone: utc) == nil)
  }

  @Test("R-CUR-2: amounts become exact minor units of their currency")
  func minorUnits() throws {
    #expect(MinorUnits.from(try #require(SaldoAmount.parse("1234.56")), currencyCode: "PLN") == 123_456)
    #expect(MinorUnits.from(try #require(SaldoAmount.parse("2000.00")), currencyCode: "HUF") == 200_000)
    #expect(MinorUnits.from(try #require(SaldoAmount.parse("1500.00")), currencyCode: "JPY") == 1500)
    #expect(MinorUnits.from(try #require(SaldoAmount.parse("0.125")), currencyCode: "EUR") == 12)
    #expect(SaldoAmount.parse("-1.00") == nil)
    #expect(SaldoAmount.parse("1,00") == nil)
    #expect(SaldoAmount.parse("") == nil)
  }

  @Test("R-TX-6: pro rata split is exact and gives leftovers to the largest remainder")
  func proRata() {
    #expect(ProRata.split(100_001, weights: [1500, 1000]) == [60_001, 40_000])
    #expect(ProRata.split(100, weights: [1, 1, 1]) == [34, 33, 33])
    #expect(ProRata.split(10, weights: [0, 0]) == [5, 5])
    #expect(ProRata.split(-7, weights: [1, 1]) == [-4, -3])
    #expect(ProRata.split(0, weights: [5]) == [0])
    let big = ProRata.split(9_000_000_000_000, weights: [3_000_000_000, 6_000_000_000])
    #expect(big == [3_000_000_000_000, 6_000_000_000_000])
  }
}
