import AbacusDomain
@testable import AbacusImport
import AbacusTestSupport
import Foundation
import Testing

/// Reads the owner's real PKO export from `$ABACUS_SAMPLES`; skipped when it is missing.
/// Prints counts only — never values from the file (R-NF-6).
@Suite("PKO real export", .tags(.realData))
struct PKORealDataTests {
  @Test("R-IMP-PKO-1, R-IMP-PKO-3: every row of the real export parses", .enabled(if: RealSamples.has(prefix: "pko")))
  func realExport() throws {
    let url = try #require(RealSamples.file(prefix: "pko"))
    let data = try Data(contentsOf: url)
    #expect(PKOParser.canParse(data))

    let parser = PKOParser(accountID: UUID(), currency: .PLN)
    let parsed = try parser.parse(data)
    let text = try #require(PKOText.decode(data))
    let dataRows = PKOText.records(text).count - 1

    #expect(parsed.rows.count == dataRows)
    #expect(parsed.skippedRowCount == 0)
    #expect(parsed.warnings.isEmpty)
    #expect(parsed.rows.allSatisfy { $0.warnings.isEmpty })

    let fingerprints = parsed.rows.flatMap(\.fingerprints)
    #expect(Set(fingerprints).count == fingerprints.count)
    #expect(try parser.parse(data).rows.flatMap(\.fingerprints) == fingerprints)

    var byKind: [String: Int] = [:]
    for row in parsed.rows { byKind[row.kind.rawValue, default: 0] += 1 }
    let summary = byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    print(
      "PKO real export: \(parsed.rows.count) rows; \(summary); pending \(parsed.rows.filter(\.isPending).count); "
        + "refunds \(parsed.rows.filter(\.isRefund).count); with original amount \(parsed.rows.filter { $0.original != nil }.count); "
        + "with counterparty account \(parsed.rows.filter { $0.counterpartyIBAN != nil }.count); "
        + "with warnings \(parsed.rows.filter { !$0.warnings.isEmpty }.count)")
  }
}
