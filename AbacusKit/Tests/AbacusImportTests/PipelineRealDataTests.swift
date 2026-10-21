import AbacusDomain
import AbacusStore
import AbacusTestSupport
import Foundation
import Testing

@testable import AbacusImport

/// The owner's real exports through the headless path (defaults) into an in-memory store.
/// Skipped when the files are missing; prints counts only — never names, amounts or
/// descriptions (R-NF-6).
@Suite(
  "Import pipeline — real exports", .tags(.realData),
  .enabled(if: RealSamples.has(prefix: "saldo") && RealSamples.has(prefix: "pko")))
struct PipelineRealDataTests {
  typealias Env = PipelineIntegrationTests.Env

  /// Booked balances of a PKO statement: the one before its earliest row and the latest one,
  /// found by chaining `balance after − amount` (rows are not strictly ordered).
  static func statementBalances(_ data: Data) throws -> (opening: Int64, latest: Int64, holds: Int64, firstDay: Day) {
    let text = try #require(PKOText.decode(data))
    var afters: [Int64] = []
    var befores: [Int64] = []
    var holds: Int64 = 0
    var days: [Day] = []
    for record in PKOText.records(text).dropFirst() {
      let fields = record.fields.map(\.pkoTrimmed)
      let amount = try #require(PKOAmount.minorUnits(fields[3]))
      if let day = Day(fields[1]) ?? Day(fields[0]) { days.append(day) }
      guard let after = PKOAmount.minorUnits(fields[5]) else {
        holds += amount
        continue
      }
      afters.append(after)
      befores.append(after - amount)
    }
    let openings = befores.filter { !afters.contains($0) }
    let latests = afters.filter { !befores.contains($0) }
    #expect(openings.count == 1)
    #expect(latests.count == 1)
    return (try #require(openings.first), try #require(latests.first), holds, try #require(days.min()))
  }

  @Test("R-IMP-1…8, R-ACC-3, R-NF-2: real Saldo then real PKO — balances, re-import, counts")
  func realSaldoThenPKO() async throws {
    let env = try Env(calendar: .current)
    let pipeline = env.pipeline

    // Saldo.
    let saldoData = try Data(contentsOf: try #require(RealSamples.file(prefix: "saldo")))
    let clock = ContinuousClock()
    let start = clock.now
    let saldoPreview = try await pipeline.preview(data: saldoData, fileName: "saldo.csv", pkoAccountID: nil)
    let previewTime = clock.now - start
    let saldoReady = saldoPreview.acceptingDefaults()
    #expect(saldoReady.canCommit)
    let saldoSummary = try await pipeline.commit(saldoReady)
    let saldoTime = clock.now - start
    print(
      "Real Saldo: rows \(saldoPreview.rows.count) · new \(saldoPreview.counts.new) · review \(saldoPreview.counts.needsReview) "
        + "· skipped \(saldoPreview.counts.skipped) · created \(saldoSummary.created) (paired transfers \(saldoSummary.transfersPaired)) "
        + "· accounts \(saldoSummary.accountsCreated) · categories \(saldoSummary.categoriesCreated) · events \(saldoSummary.eventsCreated) "
        + "· with warnings \(saldoSummary.warningsKept) · preview \(previewTime) · preview+commit \(saldoTime)")
    #expect(saldoTime < .seconds(10))

    let expected = try RowEffects.legBalances(saldoData)
    let actual = try await env.saldoBalances()
    let mismatched = Set(expected.keys).union(actual.keys).filter { expected[$0] != actual[$0] }
    print("Real Saldo: \(expected.count) accounts with a balance, \(mismatched.count) mismatched")
    #expect(mismatched.isEmpty)

    let saldoAgain = try await pipeline.preview(data: saldoData, fileName: "saldo.csv", pkoAccountID: nil)
    print("Real Saldo re-import: new \(saldoAgain.counts.new), already imported \(saldoAgain.counts.alreadyImported)")
    #expect(saldoAgain.counts.new == 0)
    #expect(saldoAgain.transactionsToCreate == 0)

    // PKO: how much of the statement Saldo already covers, per PLN account (preview only).
    let pkoData = try Data(contentsOf: try #require(RealSamples.file(prefix: "pko")))
    let plnAccounts = try await env.accounts.accounts(includeArchived: false).filter { $0.currency == .PLN }
    var bestOverlap = 0
    for account in plnAccounts {
      let probe = try await pipeline.preview(data: pkoData, fileName: "pko.csv", pkoAccountID: account.id)
      bestOverlap = max(bestOverlap, probe.counts.possibleDuplicate)
    }
    print("Real PKO vs Saldo: \(plnAccounts.count) PLN accounts probed, most possible duplicates on one account: \(bestOverlap)")

    // PKO into a fresh account opened at the statement's starting balance.
    let statement = try Self.statementBalances(pkoData)
    let target = Account(
      name: "Statement test", currency: .PLN, kind: .bank, openingBalanceMinor: statement.opening,
      openingDate: statement.firstDay.date(calendar: env.calendar))
    try await env.accounts.save(target)
    let pkoPreview = try await pipeline.preview(data: pkoData, fileName: "pko.csv", pkoAccountID: target.id)
    let pkoSummary = try await pipeline.commit(pkoPreview.acceptingDefaults())
    print(
      "Real PKO: rows \(pkoPreview.rows.count) · new \(pkoPreview.counts.new) · review \(pkoPreview.counts.needsReview) "
        + "· possible duplicates \(pkoPreview.counts.possibleDuplicate) · created \(pkoSummary.created) · settled \(pkoSummary.settled)")
    #expect(pkoPreview.counts.possibleDuplicate == 0)

    // Holds are imported as completed payments (R-IMP-PKO-2), the booked balance excludes them.
    let balance = try await env.balances()[target.id]
    let matches = balance == statement.latest + statement.holds
    print("Real PKO: balance after import equals the latest booked balance (holds included as spent): \(matches)")
    #expect(balance == statement.latest + statement.holds)

    let pkoAgain = try await pipeline.preview(data: pkoData, fileName: "pko.csv", pkoAccountID: nil)
    #expect(pkoAgain.targetAccountID == target.id)
    #expect(pkoAgain.counts.new == 0)
    print("Real PKO re-import: new \(pkoAgain.counts.new), already imported \(pkoAgain.counts.alreadyImported)")
  }
}
