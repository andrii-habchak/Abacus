import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C30, R-TX-4: refund links (migration v15), the repository rules and the reporting they feed.
@Suite("Refund links (v15)")
struct RefundLinksStoreTests {
  typealias F = StoreFixture

  static let eurToPln = FixedConverter(rates: ["PLNEUR": Decimal(string: "0.25")!, "EURPLN": 4])

  func refunds(_ f: F, rates: (any CurrencyConverter)? = RefundLinksStoreTests.eurToPln) -> SQLiteRefundRepository {
    SQLiteRefundRepository(database: f.database, calendar: F.calendar, converter: { rates })
  }

  /// A 450.00 expense (id 100, groceries) and a 450.00 incoming refund candidate (id 101, income).
  func seed(_ f: F) async throws {
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 450_00, F.groceries, payee: "Booking.com"))
  }

  // MARK: Migration

  @Test("v15 adds refundOfID to a v14 database, existing rows stay unlinked, running again is a no-op")
  func migration() throws {
    let queue = try DatabaseQueue()
    try AbacusDatabase.migrator().migrate(queue, upTo: "v14: txns.isBalanceCorrection")
    try queue.write { db in
      let before = try db.columns(in: "txns").contains { $0.name == "refundOfID" }
      #expect(!before)
      try db.execute(
        sql: #"INSERT INTO "accounts" ("id", "name", "currency", "kind", "openingBalanceMinor", "openingDate") VALUES ('a1', 'A', 'PLN', 'bank', 0, '2026-01-01 00:00:00.000')"#)
      try db.execute(
        sql: #"INSERT INTO "txns" ("id", "type", "occurredAt", "accountID", "amountMinor", "createdAt") VALUES ('t1', 'expense', '2026-03-01 12:00:00.000', 'a1', 100, '2026-03-01 12:00:00.000')"#)
    }
    try AbacusDatabase.migrator().migrate(queue)
    try AbacusDatabase.migrator().migrate(queue)
    try queue.read { db in
      let hasColumn = try db.columns(in: "txns").contains { $0.name == "refundOfID" }
      let unlinked = try Int.fetchOne(db, sql: #"SELECT count(*) FROM "txns" WHERE "refundOfID" IS NULL"#)
      #expect(hasColumn)
      #expect(unlinked == 1)
    }
  }

  // MARK: Link / unlink

  @Test("linking an expense refund copies the original's category; unlinking keeps it")
  func linkAndUnlink() async throws {
    let f = try F()
    try await seed(f)
    try await f.insert(F.expense(101, "2026-03-10", 450_00, F.fees, payee: "Booking.com", refund: true))
    try await refunds(f).linkRefund(F.id(101), to: F.id(100))
    var refund = try #require(try await f.txns.transaction(F.id(101))).txn
    #expect(refund.refundOfID == F.id(100))
    #expect(refund.categoryID == F.groceries.id)
    #expect(refund.isRefund && refund.type == .expense)
    try await refunds(f).unlinkRefund(F.id(101))
    refund = try #require(try await f.txns.transaction(F.id(101))).txn
    #expect(refund.refundOfID == nil)
    #expect(refund.categoryID == F.groceries.id)
    #expect(refund.isRefund)
  }

  @Test("an income becomes an expense refund of the original's category")
  func incomeBecomesRefund() async throws {
    let f = try F()
    try await seed(f)
    try await f.insert(F.income(101, "2026-03-10", 200_00, F.salary, payee: "Booking.com"))
    try await refunds(f).linkRefund(F.id(101), to: F.id(100))
    let refund = try #require(try await f.txns.transaction(F.id(101))).txn
    #expect(refund.type == .expense && refund.isRefund)
    #expect(refund.categoryID == F.groceries.id)
    #expect(refund.refundOfID == F.id(100))
    // Money in, as before: the balance effect of the row does not change.
    #expect(Calc.mainEffects(of: refund).first?.amountMinor == 200_00)
  }

  @Test("target and source must be eligible")
  func eligibility() async throws {
    let f = try F()
    try await seed(f)
    try await f.insert(F.expense(101, "2026-03-10", 50_00, F.fees, refund: true))
    try await f.insert(F.expense(102, "2026-03-10", 50_00, F.fees))
    try await f.insert(F.transfer(103, "2026-03-10", from: F.bank, to: F.loan, 50_00))
    var correction = F.income(104, "2026-03-10", 50_00, nil)
    correction.isBalanceCorrection = true
    try await f.insert(correction)
    let repo = refunds(f)
    // A refund cannot be the original, a transfer cannot be a refund or an original, an expense that is not a refund cannot be linked.
    await #expect(throws: RefundError.notRefundable) { try await repo.linkRefund(F.id(101), to: F.id(101)) }
    try await f.insert(F.expense(105, "2026-03-11", 10_00, F.fees, refund: true))
    await #expect(throws: RefundError.invalidOriginal) { try await repo.linkRefund(F.id(105), to: F.id(101)) }
    await #expect(throws: RefundError.invalidOriginal) { try await repo.linkRefund(F.id(105), to: F.id(103)) }
    await #expect(throws: RefundError.notRefundable) { try await repo.linkRefund(F.id(102), to: F.id(100)) }
    await #expect(throws: RefundError.notRefundable) { try await repo.linkRefund(F.id(103), to: F.id(100)) }
    await #expect(throws: RefundError.notRefundable) { try await repo.linkRefund(F.id(104), to: F.id(100)) }
    await #expect(throws: RefundError.notFound) { try await repo.linkRefund(F.id(999), to: F.id(100)) }
  }

  @Test("several refunds may share an expense, their sum may not exceed it")
  func cap() async throws {
    let f = try F()
    try await seed(f)
    for (n, amount) in [(101, 200_00), (102, 200_00), (103, 100_00)] {
      try await f.insert(F.expense(n, "2026-03-1\(n - 100)", Int64(amount), nil, refund: true))
    }
    let repo = refunds(f)
    try await repo.linkRefund(F.id(101), to: F.id(100))
    try await repo.linkRefund(F.id(102), to: F.id(100))
    await #expect(throws: RefundError.exceedsOriginal(remainingMinor: 50_00, currency: .PLN)) {
      try await repo.linkRefund(F.id(103), to: F.id(100))
    }
    // Linking the same refund again is not counted twice.
    try await repo.linkRefund(F.id(101), to: F.id(100))
    try await f.insert(F.expense(104, "2026-03-15", 50_00, nil, refund: true))
    try await repo.linkRefund(F.id(104), to: F.id(100))
  }

  @Test("cross-currency: the refund counts converted at its date's rate")
  func crossCurrency() async throws {
    let f = try F()
    try f.seedBasics()
    // 100.00 EUR on the card; refunds arrive on the PLN account (0.25 EUR per PLN).
    try await f.insert(F.expense(100, "2026-03-02", 100_00, F.transport, account: F.card))
    try await f.insert(F.expense(101, "2026-03-10", 240_00, nil, refund: true))
    try await f.insert(F.expense(102, "2026-03-11", 200_00, nil, refund: true))
    let repo = refunds(f)
    try await repo.linkRefund(F.id(101), to: F.id(100))  // 60.00 EUR
    await #expect(throws: RefundError.exceedsOriginal(remainingMinor: 40_00, currency: .EUR)) {
      try await repo.linkRefund(F.id(102), to: F.id(100))  // 50.00 EUR > 40.00
    }
    await #expect(throws: RefundError.rateUnavailable) {
      try await self.refunds(f, rates: nil).linkRefund(F.id(102), to: F.id(100))
    }
    let linked = try #require(try await f.txns.transaction(F.id(101))).txn
    #expect(linked.categoryID == F.transport.id)
  }

  @Test("deleting the original unlinks its refunds; they keep their own category")
  func deleteOriginal() async throws {
    let f = try F()
    try await seed(f)
    try await f.insert(F.expense(101, "2026-03-10", 100_00, nil, refund: true))
    try await refunds(f).linkRefund(F.id(101), to: F.id(100))
    try await f.txns.delete(F.id(100))
    let refund = try #require(try await f.txns.transaction(F.id(101))).txn
    #expect(refund.refundOfID == nil)
    #expect(refund.isRefund)
    #expect(refund.categoryID == F.groceries.id)
  }

  @Test("editing the original's category moves its linked refunds; making it a transfer unlinks them")
  func originalChanges() async throws {
    let f = try F()
    try await seed(f)
    try await f.insert(F.expense(101, "2026-03-10", 100_00, nil, refund: true))
    try await refunds(f).linkRefund(F.id(101), to: F.id(100))
    var original = try #require(try await f.txns.transaction(F.id(100))).txn
    original.categoryID = F.transport.id
    try await f.txns.save(original, lines: [])
    #expect(try await f.txns.transaction(F.id(101))?.txn.categoryID == F.transport.id)
    // Another category reassignment (merge) moves both together.
    try await f.categories.delete(F.transport.id, reassignTo: F.fees.id)
    #expect(try await f.txns.transaction(F.id(101))?.txn.categoryID == F.fees.id)
    original = try #require(try await f.txns.transaction(F.id(100))).txn
    original.type = .transfer
    original.categoryID = nil
    original.toAccountID = F.card.id
    original.toAmountMinor = 100_00
    try await f.txns.save(original, lines: [])
    #expect(try await f.txns.transaction(F.id(101))?.txn.refundOfID == nil)
  }

  @Test("saving a row that is not an expense refund drops a link it carried")
  func saveClearsInvalidLink() async throws {
    let f = try F()
    try await seed(f)
    var income = F.income(101, "2026-03-10", 10_00, F.salary)
    income.refundOfID = F.id(100)
    try await f.insert(income)
    #expect(try await f.txns.transaction(F.id(101))?.txn.refundOfID == nil)
  }

  // MARK: Candidates

  @Test("candidates: same description and amount first, same currency, 60-day window, fully refunded left out")
  func candidateRanking() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 450_00, F.groceries, payee: "Booking.com"))
    try await f.insert(F.expense(101, "2026-03-03", 450_00, F.groceries, payee: "Other shop"))
    try await f.insert(F.expense(102, "2026-03-04", 300_00, F.groceries, payee: "booking.com"))
    try await f.insert(F.expense(103, "2026-03-05", 450_00, F.groceries, account: F.card, payee: "Booking.com"))
    try await f.insert(F.expense(104, "2025-12-01", 450_00, F.groceries, payee: "Booking.com"))  // outside the window
    try await f.insert(F.expense(105, "2026-03-06", 450_00, F.groceries, payee: "Booking.com"))  // fully refunded below
    try await f.insert(F.expense(106, "2026-03-07", 99_00, F.groceries, payee: "Booking.com"))  // smaller than the refund
    try await f.insert(F.expense(107, "2026-03-20", 450_00, F.groceries, payee: "Booking.com", refund: true))
    try await f.insert(F.expense(110, "2026-03-09", 450_00, nil, payee: "Booking.com", refund: true))
    try await f.insert(F.expense(111, "2026-03-25", 450_00, nil, payee: "booking.COM", refund: true))
    let repo = refunds(f)
    try await repo.linkRefund(F.id(110), to: F.id(105))
    let candidates = try await repo.refundCandidates(for: F.id(111), limit: 10)
    let ids = candidates.map(\.txn.id)
    // Same description + amount + currency + account first; then the same amount without a
    // description match; a different currency last. 102 is smaller than the refund: left out.
    #expect(ids == [F.id(100), F.id(101), F.id(103)])
    #expect(!ids.contains(F.id(104)) && !ids.contains(F.id(105)) && !ids.contains(F.id(106)) && !ids.contains(F.id(107)))
    #expect(candidates.first?.remainingMinor == 450_00)
    #expect(try await repo.refundCandidates(for: F.id(111), limit: 2).count == 2)
    // The search drops the window.
    let searched = try await repo.refundCandidates(for: F.id(111), matching: "BOOKING", limit: 10).map(\.txn.id)
    #expect(searched.contains(F.id(104)))
    #expect(!searched.contains(F.id(101)))
  }

  @Test("targets: incoming rows on the same account, amount not above the remainder, equal amounts first")
  func targetRanking() async throws {
    let f = try F()
    try await seed(f)
    try await f.insert(F.income(101, "2026-03-10", 450_00, F.salary, payee: "Booking.com"))
    try await f.insert(F.income(102, "2026-03-11", 100_00, F.salary))
    try await f.insert(F.income(103, "2026-03-11", 900_00, F.salary))  // above the remainder
    try await f.insert(F.income(104, "2026-03-11", 450_00, F.salary, account: F.card))  // other account
    try await f.insert(F.expense(105, "2026-03-12", 450_00, nil, refund: true))
    try await f.insert(F.income(106, "2026-03-12", 450_00, F.salary, reversal: true))  // money out: no
    let repo = refunds(f)
    let targets = try await repo.refundTargets(for: F.id(100), limit: 10)
    #expect(targets.map(\.txn.id).prefix(2).contains(F.id(101)))
    #expect(Set(targets.map(\.txn.id)) == [F.id(101), F.id(102), F.id(105)])
    #expect(targets.first?.txn.id == F.id(101))
    try await f.insert(F.expense(107, "2026-03-13", 400_00, nil, refund: true))
    try await repo.linkRefund(F.id(107), to: F.id(100))
    // 50.00 remain: nothing bigger is offered.
    #expect(try await repo.refundTargets(for: F.id(100), limit: 10).isEmpty)
  }

  // MARK: List data

  @Test("refundLinks: refunds per original and the original per refund, in two reads")
  func listData() async throws {
    let f = try F()
    try await seed(f)
    try await f.insert(F.expense(101, "2026-03-10", 100_00, nil, refund: true))
    try await f.insert(F.expense(102, "2026-03-12", 50_00, nil, refund: true))
    try await f.insert(F.expense(103, "2026-03-12", 5_00, F.fees))
    let repo = refunds(f)
    try await repo.linkRefund(F.id(101), to: F.id(100))
    try await repo.linkRefund(F.id(102), to: F.id(100))
    let summary = try await repo.refundLinks(for: [F.id(100), F.id(101), F.id(103)])
    #expect(summary.refundsByOriginal[F.id(100)]?.map(\.refundID) == [F.id(101), F.id(102)])
    #expect(summary.refundsByOriginal[F.id(100)]?.map(\.amountMinor).reduce(0, +) == 150_00)
    #expect(summary.originalByRefund[F.id(101)]?.originalID == F.id(100))
    #expect(summary.originalByRefund[F.id(101)]?.payee == "Booking.com")
    #expect(summary.originalByRefund[F.id(102)] == nil)  // not asked for
    #expect(summary.originalByRefund[F.id(103)] == nil)
  }

  // MARK: Reporting

  @Test("SQL spending: a linked refund nets the original's category on the refund's month, with R-SET-3 off and on")
  func spendingQuery() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-02-27", 450_00, F.groceries, payee: "Booking.com"))
    try await f.insert(F.expense(101, "2026-03-10", 450_00, F.fees, payee: "Booking.com", refund: true))
    try await f.insert(F.expense(102, "2026-03-11", 20_00, F.fees, refund: true))  // unlinked
    try await refunds(f).linkRefund(F.id(101), to: F.id(100))
    for reduce in [false, true] {
      let march = try await f.reports.monthlySpending(Month(year: 2026, month: 3), refundsReduceSpending: reduce)
      let groceries = march.expenses.filter { $0.categoryID == F.groceries.id }.map(\.amountMinor).reduce(0, +)
      #expect(groceries == -450_00)
      // The refund is not income; the unlinked one follows the setting.
      #expect(march.refunds.map(\.amountMinor).reduce(0, +) == (reduce ? 0 : 20_00))
      let fees = march.expenses.filter { $0.categoryID == F.fees.id }.map(\.amountMinor).reduce(0, +)
      #expect(fees == (reduce ? -20_00 : 0))
      let february = try await f.reports.monthlySpending(Month(year: 2026, month: 2), refundsReduceSpending: reduce)
      #expect(february.expenses.map(\.amountMinor).reduce(0, +) == 450_00)
    }
  }

  @Test("list summary and totals: a linked refund is an expense reduction, an unlinked one follows R-SET-3")
  func listSummary() async throws {
    let f = try F()
    try f.seedBasics()
    try await f.insert(F.expense(100, "2026-03-02", 450_00, F.groceries))
    try await f.insert(F.expense(101, "2026-03-10", 100_00, nil, refund: true))
    try await f.insert(F.expense(102, "2026-03-11", 30_00, F.fees, refund: true))
    try await refunds(f).linkRefund(F.id(101), to: F.id(100))
    let summary = try await f.txns.summary(matching: TxnQuery())
    let linked = summary.mains.filter(\.isLinkedRefund)
    #expect(linked.count == 1 && linked.first?.amountMinor == 100_00)
    #expect(summary.mains.filter { $0.isRefund && !$0.isLinkedRefund }.count == 1)
    let (_, totals) = try await f.txns.list(matching: TxnQuery(newestFirst: false), refundsReduceSpending: false)
    let sums = totals.buckets.reduce((income: Int64(0), expense: Int64(0))) { ($0.income + $1.incomeMinor, $0.expense + $1.expenseMinor) }
    #expect(sums.expense == 350_00)  // 450 − 100
    #expect(sums.income == 30_00)  // the unlinked refund, R-SET-3 off
  }
}
