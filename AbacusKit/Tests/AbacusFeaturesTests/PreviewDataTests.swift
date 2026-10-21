import AbacusDomain
import AbacusFeatures
import SQLiteData
import Testing

@Suite("Preview data")
struct PreviewDataTests {
  @Test("Seeds an in-memory database that satisfies the schema")
  func seeds() throws {
    let database = try PreviewData.database()
    let (accounts, txns) = try database.read { db in
      (try Account.fetchCount(db), try Txn.fetchCount(db))
    }
    #expect(accounts == PreviewData.accounts.count)
    #expect(txns == PreviewData.txns.count)
  }
}
