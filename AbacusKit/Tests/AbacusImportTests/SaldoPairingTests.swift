import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

@Suite("Saldo parser — transfer pairing")
struct SaldoPairingTests {
  private func pairing() throws -> ParsedImport { try SaldoFixture.parse("pairing") }

  @Test("R-IMP-SALDO-2: a chain A → B → C within seconds pairs both legs correctly")
  func chain() throws {
    let result = try pairing()
    let first = try #require(result.row("3012"))
    #expect(first.fingerprints == ["saldo:3012", "saldo:3011"])
    #expect(first.account.key == "Bank PLN|PLN")
    #expect(first.counterAccount?.key == "Card PLN|PLN")
    let second = try #require(result.row("3014"))
    #expect(second.fingerprints == ["saldo:3014", "saldo:3013"])
    #expect(second.account.key == "Card PLN|PLN")
    #expect(second.counterAccount?.key == "Cash PLN|PLN")
  }

  @Test("R-IMP-SALDO-2: the closest incoming half wins")
  func closest() throws {
    let result = try pairing()
    #expect(try #require(result.row("3021")).fingerprints == ["saldo:3021", "saldo:3023"])
    let late = try #require(result.row("3022"))
    #expect(late.kind == .transferHalf)
    #expect(late.fingerprints == ["saldo:3022"])
  }

  @Test("R-IMP-SALDO-2: equally close halves → the earliest is paired")
  func tieEarliest() throws {
    let result = try pairing()
    #expect(try #require(result.row("3031")).fingerprints == ["saldo:3031", "saldo:3032"])
    #expect(try #require(result.row("3033")).kind == .transferHalf)
  }

  @Test("R-IMP-SALDO-2: halves at most 3 days apart pair, later ones do not")
  func window() throws {
    let result = try pairing()
    #expect(try #require(result.row("3041")).kind == .transferHalf)
    #expect(try #require(result.row("3042")).kind == .transferHalf)
    #expect(try #require(result.row("3043")).fingerprints == ["saldo:3043", "saldo:3044"])
  }

  @Test("R-IMP-SALDO-2: halves of the same account never pair")
  func sameAccount() throws {
    let result = try pairing()
    #expect(try #require(result.row("3051")).kind == .transferHalf)
    #expect(try #require(result.row("3052")).kind == .transferHalf)
  }

  @Test("R-IMP-SALDO-2: the in-transit currency must match")
  func currencyMustMatch() throws {
    let result = try pairing()
    #expect(try #require(result.row("3061")).kind == .transferHalf)
    #expect(try #require(result.row("3062")).kind == .transferHalf)
  }

  @Test("R-IMP-SALDO-2, R-TX-5: a cross-currency pair keeps both amounts; the tag of either half is kept")
  func crossCurrencyPair() throws {
    let row = try #require(try pairing().row("3071"))
    #expect(row.fingerprints == ["saldo:3071", "saldo:3072"])
    #expect(row.kind == .transfer)
    #expect(row.amountMinor == 430_000)
    #expect(row.account.currency == .UAH)
    #expect(row.counterAmountMinor == 10_000)
    #expect(row.counterAccount?.currency == .EUR)
    #expect(row.tag == "Trip 2025")
    #expect(row.payee == "To EUR card")
    #expect(row.transferHalf == nil)
  }

  @Test("R-IMP-SALDO-2: the incoming half may come first; the transfer takes the outgoing date")
  func incomingFirst() throws {
    let row = try #require(try pairing().row("3081"))
    #expect(row.fingerprints == ["saldo:3081", "saldo:3082"])
    #expect(row.occurredAt == SaldoFixture.date("2025-05-22T10:00:00"))
  }

  @Test("R-IMP-SALDO-2, R-IMP-5: an unpaired half goes to needs review with its transit amount")
  func unpairedHalf() throws {
    let result = try pairing()
    let out = try #require(result.row("3041"))
    #expect(out.kind == .transferHalf)
    #expect(out.amountMinor == 4100)
    #expect(out.transferHalf == TransferHalf(
      direction: .outgoing, transit: OriginalAmount(minorUnits: 4100, currencyCode: "PLN"),
      counterpartHint: "Money on the way"))
    let incoming = try #require(result.row("3062"))
    #expect(incoming.transferHalf?.direction == .incoming)
    #expect(incoming.transferHalf?.transit == OriginalAmount(minorUnits: 3000, currencyCode: "USD"))
    #expect(incoming.account.key == "Bank USD|USD")
  }

  @Test("R-IMP-SALDO-2: an unbalanced half keeps the account amount and warns")
  func unbalancedHalf() throws {
    let row = try #require(try pairing().row("3091"))
    #expect(row.kind == .transferHalf)
    #expect(row.amountMinor == 10_000)
    #expect(row.transferHalf?.transit.minorUnits == 9900)
    #expect(row.warnings == [SaldoWarning.unbalanced])
  }

  @Test("R-IMP-SALDO-2: totals of the pairing fixture")
  func totals() throws {
    let result = try pairing()
    let transfers = result.rows.filter { $0.kind == .transfer }
    let halves = result.rows.filter { $0.kind == .transferHalf }
    #expect(transfers.count == 7)
    #expect(transfers.allSatisfy { $0.fingerprints.count == 2 })
    #expect(halves.count == 9)
    #expect(result.rows.flatMap(\.fingerprints).count == 23)
    let data = try SaldoFixture.data("pairing")
    #expect(RowEffects.balances(result.rows).filter { $0.value != 0 } == (try RowEffects.legBalances(data)))
  }

  @Test("R-IMP-SALDO-2: the matcher maximises pairs where closest-first would strand halves")
  func matcherBeatsGreedy() {
    let t0 = Date(timeIntervalSince1970: 0)
    let eur = OriginalAmount(minorUnits: 100, currencyCode: "EUR")
    let outgoing = [
      PairingHalf(date: t0.addingTimeInterval(10), accountKey: "X", transit: eur),
      PairingHalf(date: t0.addingTimeInterval(12), accountKey: "A", transit: eur),
    ]
    let incoming = [
      PairingHalf(date: t0, accountKey: "A", transit: eur),
      PairingHalf(date: t0.addingTimeInterval(11), accountKey: "B", transit: eur),
    ]
    let pairs = TransferPairing.pair(outgoing: outgoing, incoming: incoming)
    #expect(pairs.map { [$0.outgoing, $0.incoming] } == [[0, 0], [1, 1]])
  }
}
