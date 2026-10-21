import AbacusDomain
import AbacusTestSupport
import Foundation
import Testing

@testable import AbacusImport

/// Runs against the owner's real export when it is present (never in CI). Prints counts only —
/// no names, amounts or descriptions (R-NF-6).
@Suite("Saldo parser — real export", .tags(.realData), .enabled(if: RealSamples.has(prefix: "saldo")))
struct SaldoRealDataTests {
  private func load() throws -> (Data, ParsedImport) {
    let url = try #require(RealSamples.file(prefix: "saldo"))
    let data = try Data(contentsOf: url)
    return (data, try SaldoParser().parse(data))
  }

  @Test("R-IMP-SALDO-1, R-IMP-SALDO-2: the whole export parses and ≥ 950 transfers pair")
  func wholeExport() throws {
    let (data, result) = try load()
    #expect(SaldoParser.canParse(data))

    var kinds: [NormalizedRow.Kind: Int] = [:]
    for row in result.rows { kinds[row.kind, default: 0] += 1 }
    let paired = result.rows.filter { $0.kind == .transfer && $0.fingerprints.count == 2 }.count
    let fingerprints = result.rows.flatMap(\.fingerprints)
    var warnings: [String: Int] = [:]
    for row in result.rows {
      for w in row.warnings { warnings[w, default: 0] += 1 }
    }

    let summary = [
      "rows \(result.rows.count)",
      "transactions \(fingerprints.count + result.skippedRowCount)",
      "expense \(kinds[.expense, default: 0]) (refunds \(result.rows.filter { $0.kind == .expense && $0.isRefund }.count))",
      "income \(kinds[.income, default: 0]) (reversals \(result.rows.filter { $0.kind == .income && $0.isRefund }.count))",
      "transfer \(kinds[.transfer, default: 0]) (paired halves \(paired))",
      "openingBalance \(kinds[.openingBalance, default: 0])",
      "transferHalf \(kinds[.transferHalf, default: 0])",
      "with lines \(result.rows.filter { !$0.lines.isEmpty }.count)",
      "with original \(result.rows.filter { $0.original != nil }.count)",
      "tagged \(result.rows.filter { $0.tag != nil }.count)",
      "archived accounts \(Set(result.rows.flatMap { [$0.account] + ($0.counterAccount.map { [$0] } ?? []) }.filter(\.isArchived).map(\.key)).count)",
      "skipped \(result.skippedRowCount)",
      "file warnings \(result.warnings.count)",
    ]
    print("Saldo real export: " + summary.joined(separator: " · "))
    for (message, count) in warnings.sorted(by: { $0.key < $1.key }) {
      print("Saldo real export warning ×\(count): \(message)")
    }

    #expect(Set(fingerprints).count == fingerprints.count)
    #expect(paired >= 950)
    #expect(result.skippedRowCount == 0)
  }

  @Test("R-ACC-3: account effects of the rows reproduce every Saldo account balance")
  func balances() throws {
    let (data, result) = try load()
    let expected = try RowEffects.legBalances(data)
    let actual = RowEffects.balances(result.rows).filter { $0.value != 0 }
    let mismatched = Set(expected.keys).union(actual.keys).filter { expected[$0] != actual[$0] }
    print("Saldo real export: \(expected.count) accounts with a balance, \(mismatched.count) mismatched")
    #expect(mismatched.isEmpty)
  }
}
