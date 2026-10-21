import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@Suite("Import store")
struct ImportStoreTests {
  typealias F = StoreFixture

  /// A synthetic Saldo-like batch: a new account and category, two transactions with fingerprints.
  static func saldoCommit(batchID: UUID = F.id(500), first: Int = 600) -> ImportCommit {
    let wallet = Account(id: F.id(50), name: "Wallet", currency: .PLN, kind: .cash, openingBalanceMinor: 20_00, openingDate: F.at("2026-01-01"))
    let pets = AbacusDomain.Category(id: F.id(60), name: "Pets", kind: .expense)
    let batch = ImportBatch(id: batchID, source: .saldo, fileName: "export.csv", summary: "2 new")
    let a = F.expense(first, "2026-03-02", 12_00, pets, account: wallet, payee: "Vet")
    let b = F.expense(first + 1, "2026-03-03", 8_00, F.groceries, payee: "Shop")
    return ImportCommit(
      batch: batch, newAccounts: [wallet], newCategories: [pets],
      txns: [
        TxnWithLines(txn: a, lines: [AttachedRecord(txnID: a.id, categoryID: F.fees.id, amountMinor: 50)]),
        TxnWithLines(txn: b, lines: []),
      ],
      fingerprints: [ImportFingerprint(id: "saldo:1", txnID: a.id), ImportFingerprint(id: "saldo:2", txnID: b.id)],
      mappings: [ImportMapping(source: .saldo, kind: .account, externalKey: "Wallet|PLN", targetID: wallet.id)],
      rules: [CategoryRule(pattern: "vet", categoryID: pets.id, origin: .imported)])
  }

  @Test("R-IMP-6: commit writes the batch, entities, transactions, fingerprints, mappings and rules")
  func commit() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.imports.commit(Self.saldoCommit())

    let batches = try await f.imports.batches()
    #expect(batches.map(\.id) == [F.id(500)])
    let rows = try await f.txns.transactions(matching: TxnQuery())
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.txn.importBatchID == F.id(500) })
    #expect(rows.first { $0.txn.payee == "Vet" }?.lines.count == 1)
    #expect(try await f.accounts.accounts(includeArchived: false).contains { $0.name == "Wallet" })
    #expect(try await f.imports.mappings(source: .saldo).map(\.externalKey) == ["Wallet|PLN"])
    #expect(try await f.imports.mappings(source: .pko).isEmpty)
    #expect(try await f.rules.rules().map(\.pattern) == ["vet"])
    #expect(try await f.imports.transactionCounts() == [F.id(500): 2])
  }

  @Test("R-IMP-3: fingerprint lookups find already imported rows")
  func fingerprints() async throws {
    let f = try F()
    try f.seedBasics()
    #expect(try await f.imports.existingFingerprints(["saldo:1"]).isEmpty)
    try await f.imports.commit(Self.saldoCommit())
    let found = try await f.imports.existingFingerprints(["saldo:1", "saldo:2", "saldo:3", "saldo:1"])
    #expect(found == ["saldo:1": F.id(600), "saldo:2": F.id(601)])
    // Many keys at once (chunked lookups).
    let many = (0..<2_000).map { "pko:\($0)" } + ["saldo:2"]
    #expect(try await f.imports.existingFingerprints(many) == ["saldo:2": F.id(601)])
  }

  @Test("R-IMP-6, R-IMP-3: a commit is all or nothing — a known fingerprint rolls everything back")
  func atomicCommit() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.imports.commit(Self.saldoCommit())
    // Re-importing the same rows in a new batch fails on the fingerprint, leaving nothing behind.
    var again = Self.saldoCommit(batchID: F.id(501), first: 700)
    again.newAccounts = []
    again.newCategories = []
    await #expect(throws: (any Error).self) { try await f.imports.commit(again) }
    #expect(try await f.imports.batches().count == 1)
    #expect(try await f.txns.transactions(matching: TxnQuery()).count == 2)
  }

  @Test("R-IMP-7: an import cannot overwrite existing accounts or opening balances")
  func neverOverwrites() async throws {
    let f = try F()
    try f.seedBasics()
    var bank = F.bank
    bank.openingBalanceMinor = 0
    let commit = ImportCommit(batch: ImportBatch(source: .saldo, fileName: "x.csv"), newAccounts: [bank])
    await #expect(throws: (any Error).self) { try await f.imports.commit(commit) }
    #expect(try await f.accounts.accounts(includeArchived: true).first { $0.id == F.bank.id }?.openingBalanceMinor == 1_000_00)
    #expect(try await f.imports.batches().isEmpty)
  }

  @Test("R-IMP-7, R-IMP-PKO-2: only updatedTxns change existing transactions (links, settled holds)")
  func updatesExisting() async throws {
    let f = try F()
    try f.seedBasics()
    var hold = F.expense(100, "2026-03-02", 20_00, F.groceries, payee: "Shop")
    hold.isPendingAtBank = true
    hold.source = .pko
    try await f.insert(hold)
    try await f.insert(F.expense(101, "2026-03-02", 20_00, F.groceries, payee: "Other"))
    #expect(try await f.imports.pendingTxns(accountID: F.bank.id, from: Day("2026-03-01")!, to: Day("2026-03-05")!).map(\.id) == [hold.id])

    var settled = hold
    settled.isPendingAtBank = false
    settled.amountMinor = 21_00
    let commit = ImportCommit(
      batch: ImportBatch(id: F.id(500), source: .pko, fileName: "pko.csv", accountID: F.bank.id),
      fingerprints: [ImportFingerprint(id: "pko:settled", txnID: hold.id)],
      updatedTxns: [settled])
    try await f.imports.commit(commit)

    #expect(try await f.txns.transaction(hold.id)?.txn.amountMinor == 21_00)
    #expect(try await f.txns.transaction(F.id(101))?.txn.amountMinor == 20_00)
    #expect(try await f.imports.pendingTxns(accountID: F.bank.id, from: Day("2026-03-01")!, to: Day("2026-03-05")!).isEmpty)
    #expect(try await f.imports.existingFingerprints(["pko:settled"]) == ["pko:settled": hold.id])

    // Undo removes the link fingerprint; the existing transaction stays.
    try await f.imports.undo(F.id(500))
    #expect(try await f.imports.existingFingerprints(["pko:settled"]).isEmpty)
    #expect(try await f.txns.transaction(hold.id) != nil)

    // Updating a transaction that does not exist fails the commit.
    var ghost = settled
    ghost = Txn(id: F.id(999), type: .expense, occurredAt: ghost.occurredAt, accountID: F.bank.id, amountMinor: 1)
    let bad = ImportCommit(batch: ImportBatch(source: .pko, fileName: "pko.csv"), updatedTxns: [ghost])
    await #expect(throws: RepositoryError.notFound) { try await f.imports.commit(bad) }
  }

  @Test("R-IMP-6: undo deletes the batch's transactions and fingerprints and marks it undone")
  func undo() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 1_00, F.groceries))  // manual, untouched
    try await f.imports.commit(Self.saldoCommit())
    try await f.imports.undo(F.id(500))

    #expect(try await f.txns.transactions(matching: TxnQuery()).map(\.txn.id) == [F.id(100)])
    #expect(try await f.imports.existingFingerprints(["saldo:1", "saldo:2"]).isEmpty)
    let lines = try await f.database.read { db in try AttachedRecord.fetchCount(db) }
    #expect(lines == 0)
    #expect(try await f.imports.batches().first?.isUndone == true)
    // Undoing twice is harmless; the rows can be imported again.
    try await f.imports.undo(F.id(500))
    var again = Self.saldoCommit(batchID: F.id(501))
    again.newAccounts = []
    again.newCategories = []
    try await f.imports.commit(again)
    #expect(try await f.txns.transactions(matching: TxnQuery()).count == 3)
    await #expect(throws: RepositoryError.notFound) { try await f.imports.undo(F.id(999)) }
  }

  @Test("R-IMP-4: dedupe candidates match account, amount and the date window (either transfer side)")
  func candidates() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 20_00, F.groceries))
    try await f.insert(F.expense(101, "2026-03-09", 20_00, F.groceries))  // outside the window
    try await f.insert(F.expense(102, "2026-03-03", 21_00, F.groceries))  // other amount
    try await f.insert(F.transfer(103, "2026-03-04", from: F.card, to: F.bank, 5_00, received: 20_00))
    let found = try await f.imports.candidates(accountID: F.bank.id, amountMinor: 20_00, from: Day("2026-03-01")!, to: Day("2026-03-05")!)
    #expect(found.map(\.id) == [F.id(100), F.id(103)])
  }

  @Test("R-IMP-2: a new mapping replaces the remembered one for the same source key")
  func mappingReplace() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.imports.commit(Self.saldoCommit())
    let remap = ImportCommit(
      batch: ImportBatch(source: .saldo, fileName: "second.csv"),
      mappings: [ImportMapping(source: .saldo, kind: .account, externalKey: "Wallet|PLN", targetID: F.bank.id)])
    try await f.imports.commit(remap)
    #expect(try await f.imports.mappings(source: .saldo).map(\.targetID) == [F.bank.id])
  }
}
