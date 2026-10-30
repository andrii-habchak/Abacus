import AbacusDomain
import AbacusTestSupport
import Foundation
import Testing

@testable import AbacusImport

/// C16: a PKO hold (`Blokada`) is money out whatever sign its amount carries, and its settled
/// payment still upgrades it (R-IMP-PKO-2). Synthetic rows only.
@Suite("PKO pending hold direction")
struct PendingHoldSignTests {
  typealias F = PipelineFixture

  static func hold(_ amount: String, day: String = "2026-01-15", merchant: String = "GROCERY EXAMPLE") -> String {
    #""","\#(day)","Blokada","\#(amount)","PLN","W rozliczeniu","Tytuł: P000000000000000000031","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  static func settled(_ amount: String = "-41.20", booked: String = "2026-01-17", value: String = "2026-01-15") -> String {
    #""\#(booked)","\#(value)","Płatność kartą","\#(amount)","PLN","+958.80","Tytuł:  000000000000000000000032 ","Lokalizacja: Adres: GROCERY EXAMPLE Miasto: Warszawa Kraj: POLSKA","Data wykonania operacji: \#(value)","Oryginalna kwota operacji: 41.20","Numer karty: 000000******0000","""#
  }

  // MARK: Parser

  @Test("R-IMP-PKO-2: a hold is a pending expense whether its amount is signed -, + or unsigned", arguments: ["-41.20", "41.20", "+41.20"])
  func holdIsExpense(amount: String) throws {
    let parsed = try PKOFixtures.parser.parse(PKOFixtures.file([Self.hold(amount)]))
    let row = try #require(parsed.rows.first)
    #expect(row.isPending)
    #expect(row.kind == .expense)
    #expect(!row.isRefund)
    #expect(row.flow == .out)
    #expect(row.amountMinor == 41_20)
    #expect(row.warnings.isEmpty)
    // The fingerprint keeps the file's text, so holds imported before the fix still match.
    #expect(
      row.fingerprints == [
        Fingerprint.pko(accountID: PKOFixtures.accountID, parts: ["hold", "2026-01-15", amount, "P000000000000000000031"])
      ])
  }

  @Test("R-IMP-PKO-3: money in stays money in — a positive card payment is a refund, an incoming transfer income")
  func creditsStayInflow() throws {
    let refund = Self.settled("+41.20")
    let incoming =
      #""2026-01-16","2026-01-16","Przelew na konto","+120.00","PLN","+1078.80","Rachunek nadawcy: 00 0000 0000 0000 0000 0000 0000","Nazwa nadawcy: JAN PRZYKŁADOWY","Tytuł: ZWROT","","","""#
    let parsed = try PKOFixtures.parser.parse(PKOFixtures.file([refund, incoming]))
    #expect(parsed.rows.count == 2)
    let card = try parsed.row(payee: "GROCERY EXAMPLE")
    #expect(card.kind == .expense && card.isRefund && card.flow == .in && !card.isPending)
    let transfer = try parsed.row(payee: "JAN PRZYKŁADOWY")
    #expect(transfer.kind == .income && transfer.flow == .in)
  }

  // MARK: Pipeline

  @Test("R-IMP-PKO-2: an unsigned hold shows as money out, commits as an expense, and its settled payment upgrades it")
  func holdThenSettled() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let pipeline = db.pipeline()

    let first = try await pipeline.preview(
      data: PKOFixtures.file([Self.hold("41.20")]), fileName: "pko-1.csv", targetAccountID: F.pkoAccount.id)
    let row = try #require(first.rows.first)
    #expect(row.type == .expense)
    #expect(!row.isInflow)
    #expect(row.detail == "Pending at the bank")
    try await pipeline.commit(first)
    let hold = try #require(db.txns.first { $0.isPendingAtBank })
    #expect(hold.type == .expense && !hold.isRefund && hold.amountMinor == 41_20)
    #expect(db.balance(F.pkoAccount.id) == F.pkoAccount.openingBalanceMinor - 41_20)

    let later = try await pipeline.preview(
      data: PKOFixtures.file([Self.settled()]), fileName: "pko-2.csv", targetAccountID: F.pkoAccount.id)
    #expect(later.counts.settlesPending == 1)
    #expect(later.rows.first?.isInflow == false)
    let summary = try await pipeline.commit(later)
    #expect(summary.settled == 1)
    #expect(summary.created == 0)
    #expect(db.txns.count == 1)
    let upgraded = try #require(db.txns.first { $0.id == hold.id })
    #expect(!upgraded.isPendingAtBank && !upgraded.isRefund)
    #expect(upgraded.bookedDay == "2026-01-17")
    #expect(db.balance(F.pkoAccount.id) == F.pkoAccount.openingBalanceMinor - 41_20)
  }

  @Test("R-IMP-PKO-2: a hold stored as a refund by an older build is settled and repaired, not duplicated")
  func wrongSignHoldRepairedOnSettle() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let stale = Txn(
      type: .expense, occurredAt: F.calendar.startOfDay(for: F.date("2026-01-15")), accountID: F.pkoAccount.id,
      amountMinor: 41_20, isRefund: true, payee: "GROCERY EXAMPLE", source: .pko, isPendingAtBank: true)
    db.txns = [stale]

    let later = try await db.pipeline().preview(
      data: PKOFixtures.file([Self.settled()]), fileName: "pko-2.csv", targetAccountID: F.pkoAccount.id)
    #expect(later.counts.settlesPending == 1)
    try await db.pipeline().commit(later)
    #expect(db.txns.count == 1)
    let repaired = try #require(db.txns.first)
    #expect(repaired.id == stale.id)
    #expect(!repaired.isPendingAtBank && !repaired.isRefund)
    #expect(db.balance(F.pkoAccount.id) == F.pkoAccount.openingBalanceMinor - 41_20)
  }
}
