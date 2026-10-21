import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// Shared helpers for the Saldo parser tests (fixtures are synthetic, see Fixtures/saldo/).
enum SaldoFixture {
  static let utc = TimeZone(identifier: "UTC")!

  static func data(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/saldo/\(name)", withExtension: "csv"))
    return try Data(contentsOf: url)
  }

  static func parse(_ name: String) throws -> ParsedImport {
    try SaldoParser(timeZone: utc).parse(data(name))
  }

  static func parse(text: String) throws -> ParsedImport {
    try SaldoParser(timeZone: utc).parse(Data(text.utf8))
  }

  static let header =
    #""Transaction ID","Transaction Date","Description","Parent account","Account","Account Type","Archived","Journal Type","Amount","Currency","Tags","Accrual Month","Notes""#

  static func date(_ string: String) -> Date {
    SaldoDate.parse(string, timeZone: utc)!
  }
}

extension ParsedImport {
  /// The row that carries `saldo:<id>`.
  func row(_ id: String) -> NormalizedRow? {
    rows.first { $0.fingerprints.contains("saldo:\(id)") }
  }
}

/// Account effects of normalised rows, signed debit-positive like Saldo (asset +, outflow −).
enum RowEffects {
  static func lineEffect(_ line: NormalizedLine) -> Int64 {
    line.kind == .expense ? -line.amountMinor : line.amountMinor
  }

  /// `[account key: effect]` for one row.
  static func effects(of row: NormalizedRow) -> [String: Int64] {
    let lines = row.lines.map(lineEffect).reduce(0, +)
    switch row.kind {
    case .expense:
      return [row.account.key: (row.isRefund ? row.amountMinor : -row.amountMinor) + lines]
    case .income:
      return [row.account.key: (row.isRefund ? -row.amountMinor : row.amountMinor) + lines]
    case .openingBalance:
      return [row.account.key: row.amountMinor]
    case .transfer:
      var result = [row.account.key: -row.amountMinor + lines]
      if let to = row.counterAccount {
        result[to.key, default: 0] += row.counterAmountMinor ?? 0
      }
      return result
    case .transferHalf:
      let outgoing = row.transferHalf?.direction == .outgoing
      return [row.account.key: (outgoing ? -row.amountMinor : row.amountMinor) + lines]
    }
  }

  static func balances(_ rows: [NormalizedRow]) -> [String: Int64] {
    var result: [String: Int64] = [:]
    for row in rows {
      for (key, value) in effects(of: row) { result[key, default: 0] += value }
    }
    return result
  }

  /// Balances straight from the CSV legs: Σ DEBIT − Σ CREDIT per account leg.
  static func legBalances(_ data: Data) throws -> [String: Int64] {
    let records = try CSVReader.records(CSVReader.strippingBOM([UInt8](data)))
    let header = try #require(SaldoHeader(records[0].fields))
    var result: [String: Int64] = [:]
    for record in records.dropFirst() {
      let leg = try header.leg(from: record, timeZone: SaldoFixture.utc)
      guard leg.type?.isAccount == true else { continue }
      result[leg.accountKey, default: 0] += leg.side == .debit ? leg.minorUnits : -leg.minorUnits
    }
    return result.filter { $0.value != 0 }
  }
}
