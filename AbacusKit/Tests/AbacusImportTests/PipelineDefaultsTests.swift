import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// The headless path: `preview(data:fileName:pkoAccountID:)` → `acceptingDefaults()` → commit
/// (R-IMP-1, R-IMP-4, R-IMP-5, R-IMP-SALDO-4, R-IMP-PKO-2).
@Suite("Import pipeline defaults")
struct PipelineDefaultsTests {
  typealias F = PipelineFixture

  @Test("R-IMP-5, R-IMP-SALDO-4: unpaired halves go to Uncategorised with a review note; tags make no events")
  func saldoDefaults() async throws {
    let db = FakeDB()
    let existingIncome = AbacusDomain.Category(id: F.id(70), name: "uncategorised", kind: .income)
    db.categories = [existingIncome]
    let data = F.saldo([
      "1,2025-05-01T10:00:00,To EUR,Bank UAH,BANK_ACCOUNTS,0,CREDIT,4400.00,UAH,Trip",
      "1,2025-05-01T10:00:00,To EUR,Bank EUR,MONEY_ON_THE_WAY,0,DEBIT,4400.00,UAH,Trip",
      "2,2025-05-01T10:01:00,From UAH,Bank EUR,BANK_ACCOUNTS,0,DEBIT,100.00,EUR",
      "2,2025-05-01T10:01:00,From UAH,Bank UAH,MONEY_ON_THE_WAY,0,CREDIT,100.00,EUR",
      "3,2025-05-02T10:00:00,Lunch,Bank UAH,BANK_ACCOUNTS,0,CREDIT,50.00,UAH,Trip",
      "3,2025-05-02T10:00:00,Lunch,Eating out,EXPENSES,0,DEBIT,50.00,UAH,Trip",
    ])
    let preview = try await db.pipeline().preview(data: data, fileName: "s.csv", pkoAccountID: nil)
    #expect(!preview.canCommit)
    let ready = preview.acceptingDefaults()
    #expect(ready.canCommit)
    #expect(ready.eventCandidates.allSatisfy { !$0.isSelected })
    let mapping = try #require(ready.categoryMappings.first { $0.id == "expense|Uncategorised" })
    #expect(mapping.target == .create)
    #expect(ready.categoryMappings.first { $0.id == "income|Uncategorised" }?.target == .existing(existingIncome.id))

    let summary = try await db.pipeline().commit(ready)
    #expect(summary.created == 3)
    #expect(summary.eventsCreated == 0)
    #expect(db.events.isEmpty)
    let out = try #require(db.txn(fingerprint: "saldo:1"))
    #expect(out.type == .expense && !out.isRefund)
    #expect(out.note == ImportPreview.unpairedHalfNote)
    #expect(db.categories.first { $0.id == out.categoryID }?.name == "Uncategorised")
    #expect(db.categories.first { $0.id == out.categoryID }?.kind == .expense)
    let incoming = try #require(db.txn(fingerprint: "saldo:2"))
    #expect(incoming.type == .income && incoming.categoryID == existingIncome.id)
    #expect(db.txns.allSatisfy { $0.eventID == nil })
    // Balances are kept: money out of UAH, into EUR.
    let uah = try #require(db.accounts.first { $0.name == "Bank UAH" })
    let eur = try #require(db.accounts.first { $0.name == "Bank EUR" })
    #expect(db.balance(uah.id) == -4450_00)
    #expect(db.balance(eur.id) == 100_00)
  }

  @Test("R-IMP-5, R-IMP-4, R-IMP-PKO-2: PKO defaults — unknown types by sign, duplicates skipped, holds upgraded")
  func pkoDefaults() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.txns = [
      Txn(type: .expense, occurredAt: F.date("2026-01-10"), accountID: F.pkoAccount.id, amountMinor: 49_99, payee: "shop example", source: .saldo)
    ]
    let pipeline = db.pipeline()
    let first = try await pipeline.preview(data: F.data("pko", "all-types"), fileName: "p.csv", pkoAccountID: F.pkoAccount.id)
      .acceptingDefaults()
    #expect(first.canCommit)
    #expect(first.counts.possibleDuplicate == 1)
    let unknown = try #require(first.rows.first { $0.review?.reason == .unknownOperationType })
    #expect(unknown.type == .expense)
    #expect(unknown.category == nil)
    // The currency exchange (other account unknown) is an unpaired half: income in Uncategorised.
    let exchange = try #require(first.rows.first { $0.source.kind == .transferHalf })
    #expect(exchange.type == .income)
    #expect(exchange.category == .new(key: "income|Uncategorised"))
    let summary = try await pipeline.commit(first)
    #expect(summary.duplicatesSkipped == 1)
    #expect(summary.created == 12)

    let later = try await pipeline.preview(data: F.data("pko", "settled-later"), fileName: "p2.csv", pkoAccountID: nil)
      .acceptingDefaults()
    let laterSummary = try await pipeline.commit(later)
    #expect(laterSummary.settled == 1)
    #expect(laterSummary.created == 0)
    #expect(db.txns.filter(\.isPendingAtBank).isEmpty)
  }

  @Test("R-IMP-5: choices made before acceptDefaults are kept")
  func keepsChoices() async throws {
    let db = FakeDB()
    let data = F.saldo([
      "1,2025-05-03T10:00:00,To a friend,Bank UAH,BANK_ACCOUNTS,0,CREDIT,200.00,UAH",
      "1,2025-05-03T10:00:00,Money on the way,Money on the way,MONEY_ON_THE_WAY,0,DEBIT,200.00,UAH",
    ])
    var preview = try await db.pipeline().preview(data: data, fileName: "s.csv")
    preview.setReviewChoice(.skip, forRow: "saldo:1")
    preview.acceptDefaults()
    #expect(preview.row("saldo:1")?.review?.choice == .skip)
    #expect(!preview.categoryMappings.contains { $0.external.name == ImportPreview.uncategorisedName })
  }
}
