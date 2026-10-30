import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// The pipeline on the real SQLite store (in memory), end to end on the synthetic fixtures
/// (R-IMP-1…8, R-IMP-PKO-2, R-ACC-3).
@Suite("Import pipeline on the SQLite store")
struct PipelineIntegrationTests {
  typealias F = PipelineFixture

  /// Repositories over one in-memory database.
  struct Env {
    let database: any DatabaseWriter
    let calendar: Calendar

    init(calendar: Calendar = PipelineFixture.calendar) throws {
      database = try AbacusDatabase.open(at: nil)
      self.calendar = calendar
    }

    var store: SQLiteImportStore { SQLiteImportStore(database: database, calendar: calendar) }
    var accounts: SQLiteAccountRepository { SQLiteAccountRepository(database: database, calendar: calendar) }
    var txns: SQLiteTxnRepository { SQLiteTxnRepository(database: database, calendar: calendar) }

    var pipeline: ImportPipeline {
      ImportPipeline(
        store: store, accounts: accounts, categories: SQLiteCategoryRepository(database: database),
        events: SQLiteEventRepository(database: database), rules: SQLiteRuleRepository(database: database),
        calendar: calendar)
    }

    /// Previews, resolves review rows with their suggestions, commits.
    @discardableResult
    func importFile(_ data: Data, _ name: String, into target: Account.ID? = nil) async throws -> (ImportPreview, ImportSummary) {
      var preview = try await pipeline.preview(data: data, fileName: name, targetAccountID: target)
      preview.acceptSuggestedReviewChoices()
      return (preview, try await pipeline.commit(preview))
    }

    func allTxns() async throws -> [TxnWithLines] {
      try await txns.transactions(matching: TxnQuery())
    }

    func balances() async throws -> [Account.ID: Int64] {
      try await accounts.balances(asOf: Day("2100-01-01")!)
    }

    /// Balances by Saldo account key, via the remembered mappings. A LIABILITIES account stays a
    /// debt-kind account, linked to its debt on import (R-DEBT-17): its balance is the debt's.
    func saldoBalances() async throws -> [String: Int64] {
      let balances = try await balances()
      var result: [String: Int64] = [:]
      for mapping in try await store.mappings(source: .saldo) where mapping.kind == .account {
        result[mapping.externalKey] = balances[mapping.targetID] ?? 0
      }
      return result.filter { $0.value != 0 }
    }

    struct Snapshot: Equatable {
      var txns: [TxnWithLines]
      var accounts: [Account]
      var balances: [Account.ID: Int64]
    }

    func snapshot() async throws -> Snapshot {
      Snapshot(
        txns: try await allTxns().sorted { $0.txn.id.uuidString < $1.txn.id.uuidString },
        accounts: try await accounts.accounts(includeArchived: true).sorted { $0.id.uuidString < $1.id.uuidString },
        balances: try await balances())
    }
  }

  @Test("R-IMP-6, R-ACC-3, R-IMP-3: Saldo import reproduces the leg balances; re-import finds nothing new")
  func saldoEndToEnd() async throws {
    let env = try Env()
    let data = try F.data("saldo", "patterns")
    let (preview, summary) = try await env.importFile(data, "patterns.csv")
    #expect(summary.created == preview.transactionsToCreate)
    #expect(summary.accountsCreated > 0)

    // Every account balance equals what the parsed rows give (the fixture's one unsupported
    // transaction is skipped by the parser, so the raw legs differ by exactly that one).
    let parsed = try SaldoParser(timeZone: F.calendar.timeZone).parse(data)
    let expected = RowEffects.balances(parsed.rows).filter { $0.value != 0 }
    let actual = try await env.saldoBalances()
    #expect(actual == expected, "\(Set(actual.keys).union(expected.keys).filter { actual[$0] != expected[$0] }.map { "\($0): \(actual[$0] ?? 0) vs \(expected[$0] ?? 0)" })")
    #expect(parsed.skippedRowCount == 1)

    let again = try await env.pipeline.preview(data: data, fileName: "patterns.csv")
    #expect(again.counts.new == 0)
    #expect(again.transactionsToCreate == 0)
    #expect(again.unresolvedReviewCount == 0 || again.counts.needsReview == again.unresolvedReviewCount)
    let history = try await env.pipeline.history()
    #expect(history.first?.summary.hasPrefix("Saldo · \(summary.created) new") == true)
  }

  @Test("R-IMP-3, R-IMP-4, R-IMP-PKO-2, R-IMP-6: PKO after Saldo — duplicates skipped, hold upgraded once, undo restores")
  func pkoEndToEnd() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)

    // Saldo already holds one purchase of the PKO account.
    let saldo = F.saldo([
      "9001,2026-01-09T18:00:00,Shop example,PKO Personal,BANK_ACCOUNTS,0,CREDIT,49.99,PLN",
      "9001,2026-01-09T18:00:00,Shop example,Shopping,EXPENSES,0,DEBIT,49.99,PLN",
    ])
    let (saldoPreview, _) = try await env.importFile(saldo, "saldo.csv")
    #expect(saldoPreview.accountMappings.first?.target == .existing(F.pkoAccount.id))
    let before = try await env.snapshot()

    // First statement: the Saldo purchase is a possible duplicate, skipped by default.
    let allTypes = try F.data("pko", "all-types")
    let (first, firstSummary) = try await env.importFile(allTypes, "pko-1.csv", into: F.pkoAccount.id)
    #expect(first.counts.possibleDuplicate == 1)
    #expect(firstSummary.duplicatesSkipped == 1)
    #expect(firstSummary.created == 12)
    #expect(try await env.allTxns().count == before.txns.count + 12)

    // Undo restores the state before the statement (accounts, transactions, balances).
    try await env.pipeline.undo(first.batchID)
    #expect(try await env.snapshot() == before)
    #expect(try await env.pipeline.history().first { $0.id == first.batchID }?.isUndone == true)

    // Import it again: its fingerprints were removed with the undo.
    let (second, _) = try await env.importFile(allTypes, "pko-1.csv", into: F.pkoAccount.id)
    #expect(second.counts.new == 10)
    let afterFirst = try await env.allTxns()
    let hold = try #require(afterFirst.first { $0.txn.isPendingAtBank }?.txn)

    // Later statement: one overlapping row, one settling the hold.
    let (later, laterSummary) = try await env.importFile(F.data("pko", "settled-later"), "pko-2.csv", into: F.pkoAccount.id)
    #expect(later.counts.alreadyImported == 1)
    #expect(later.counts.settlesPending == 1)
    #expect(laterSummary.created == 0)
    #expect(laterSummary.settled == 1)
    let afterLater = try await env.allTxns()
    #expect(afterLater.count == afterFirst.count)
    let upgraded = try #require(afterLater.first { $0.txn.id == hold.id }?.txn)
    #expect(!upgraded.isPendingAtBank)
    #expect(upgraded.bookedDay == "2026-01-17")
    #expect(upgraded.occurredAt == hold.occurredAt)
    #expect(try await env.store.existingFingerprints(later.rows.flatMap(\.source.fingerprints)).count == 2)

    // Re-importing both statements finds nothing new.
    for data in [allTypes, try F.data("pko", "settled-later")] {
      let again = try await env.pipeline.preview(data: data, fileName: "again.csv", targetAccountID: F.pkoAccount.id)
      #expect(again.counts.new == 0)
      #expect(again.transactionsToCreate == 0)
    }

    // The PKO account balance: opening + the statement's effects; the skipped duplicate counted once.
    let effects = afterLater.filter { $0.txn.accountID == F.pkoAccount.id || $0.txn.toAccountID == F.pkoAccount.id }
    #expect(effects.count == 13)
    #expect(try await env.balances()[F.pkoAccount.id] == 2887_51)
  }

  @Test("R-IMP-2, R-IMP-8: mappings and learned rules persist in the store and drive the next import")
  func memoryAcrossImports() async throws {
    let env = try Env()
    try await env.accounts.save(F.pkoAccount)
    try await SQLiteCategoryRepository(database: env.database).save(F.groceries)
    var preview = try await env.pipeline.preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let grocery = try #require(preview.rows.first { $0.source.payee.contains("GROCERY") && !$0.source.isRefund })
    preview.setCategory(F.groceries.id, forRow: grocery.id)
    preview.acceptSuggestedReviewChoices()
    try await env.pipeline.commit(preview)
    let rules = try await SQLiteRuleRepository(database: env.database).rules()
    #expect(rules.map(\.pattern) == ["grocery store"])

    let next = try await env.pipeline.preview(
      data: F.pko([
        #""2026-01-25","2026-01-24","Płatność kartą","-9.99","PLN","+800.00","Tytuł: 88","Lokalizacja: Adres: GROCERY STORE Miasto: Kraków Kraj: POLSKA","","","","""#
      ]), fileName: "p2.csv")
    #expect(next.targetRemembered)
    #expect(next.rows[0].category == .existing(F.groceries.id))
    #expect(next.accountMappings.isEmpty)
  }
}
