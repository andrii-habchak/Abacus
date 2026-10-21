import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@Suite("Schema v1")
struct SchemaTests {
  @Test("Migrates an empty database and round-trips every entity")
  func roundTrip() throws {
    let database = try AbacusDatabase.open(at: nil)
    let accountID = UUID()
    let categoryID = UUID()
    let txnID = UUID()
    try database.write { db in
      try db.seed {
        Account(id: accountID, name: "Bank", currency: .PLN, kind: .bank, openingBalanceMinor: 100_00, openingDate: Date(timeIntervalSince1970: 0))
        AbacusDomain.Category(id: categoryID, name: "Groceries", kind: .expense)
        Txn(id: txnID, type: .expense, occurredAt: Date(timeIntervalSince1970: 86_400), accountID: accountID, amountMinor: 15_89, categoryID: categoryID, payee: "Shop")
        AttachedRecord(txnID: txnID, kind: .expense, categoryID: categoryID, amountMinor: 50)
        ImportFingerprint(id: "saldo:1", txnID: txnID)
        AppSetting(.displayCurrency, value: "PLN")
      }
    }
    let (accounts, txns, lines, fingerprints) = try database.read { db in
      (
        try Account.fetchAll(db), try Txn.fetchAll(db), try AttachedRecord.fetchAll(db),
        try ImportFingerprint.fetchAll(db)
      )
    }
    #expect(accounts.map(\.name) == ["Bank"])
    #expect(txns.first?.amountMinor == 15_89)
    #expect(txns.first?.categoryID == categoryID)
    #expect(lines.count == 1)
    #expect(fingerprints.map(\.id) == ["saldo:1"])
  }

  @Test("R-IMP-3: a fingerprint can only be stored once")
  func fingerprintIsUnique() throws {
    let database = try AbacusDatabase.open(at: nil)
    let accountID = UUID()
    let txnID = UUID()
    try database.write { db in
      try db.seed {
        Account(id: accountID, name: "Bank", currency: .PLN, kind: .bank, openingDate: Date())
        Txn(id: txnID, type: .expense, occurredAt: Date(), accountID: accountID, amountMinor: 1)
        ImportFingerprint(id: "pko:abc", txnID: txnID)
      }
    }
    #expect(throws: (any Error).self) {
      try database.write { db in
        try db.seed { ImportFingerprint(id: "pko:abc", txnID: txnID) }
      }
    }
  }

  @Test("Deleting a transaction cascades to its attached records and fingerprints")
  func cascade() throws {
    let database = try AbacusDatabase.open(at: nil)
    let accountID = UUID()
    let txnID = UUID()
    try database.write { db in
      try db.seed {
        Account(id: accountID, name: "Bank", currency: .PLN, kind: .bank, openingDate: Date())
        Txn(id: txnID, type: .expense, occurredAt: Date(), accountID: accountID, amountMinor: 1)
        AttachedRecord(txnID: txnID, amountMinor: 1)
        ImportFingerprint(id: "saldo:9", txnID: txnID)
      }
      try Txn.delete().where { $0.id.eq(txnID) }.execute(db)
    }
    let counts = try database.read { db in
      (try AttachedRecord.fetchCount(db), try ImportFingerprint.fetchCount(db))
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 0)
  }
}
