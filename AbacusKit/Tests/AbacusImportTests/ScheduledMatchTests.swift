import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusImport

/// N5 step 2: the matching rule (pure, R-REC-6). Synthetic data.
@Suite("Scheduled match rule (R-REC-6)")
struct ScheduledMatchRuleTests {
  typealias F = PipelineFixture

  static let account = F.id(1)
  static let other = F.id(2)

  static func item(
    _ n: Int = 100, type: TxnType = .expense, amount: Int64 = 100_00, payee: String = "Gym Club", tolerance: Int = 5,
    start: String = "2026-03-10", created: String = "2026-01-01"
  ) -> ScheduledItem {
    ScheduledItem(
      id: F.id(n), type: type, accountID: account, toAccountID: type == .transfer ? other : nil, amountMinor: amount,
      payee: payee, unit: .month, startDay: start, tolerancePercent: tolerance, createdAt: F.date(created))
  }

  static func probe(
    _ key: String = "t", day: String = "2026-03-10", amount: Int64 = 100_00, payee: String = "GYM CLUB WARSZAWA",
    type: TxnType = .expense, account: Account.ID = account
  ) -> ScheduledProbe {
    ScheduledProbe(key: key, accountID: account, type: type, amountMinor: amount, payee: payee, day: Day(day)!)
  }

  static func candidate(_ item: ScheduledItem, _ day: String = "2026-03-10") -> ScheduledCandidate {
    ScheduledCandidate(item: item, day: Day(day)!)
  }

  @Test("R-REC-6: amount within the item's tolerance (5 % default, same rule as pending settlement)")
  func amount() {
    let c = Self.candidate(Self.item())
    #expect(ScheduledMatch.matches(Self.probe(amount: 105_00), c))
    #expect(ScheduledMatch.matches(Self.probe(amount: 95_00), c))
    #expect(!ScheduledMatch.matches(Self.probe(amount: 106_00), c))
    #expect(!ScheduledMatch.matches(Self.probe(amount: 93_00), c))
    for actual: Int64 in [94_00, 95_00, 104_99, 105_00, 105_01, 106_00] {
      #expect(
        ScheduledMatch.amountMatches(expected: 100_00, actual: actual, tolerancePercent: 5)
          == PendingSettlement.amountMatches(pending: 100_00, settled: actual))
    }
    // Tolerance override.
    let wide = Self.candidate(Self.item(tolerance: 10))
    #expect(ScheduledMatch.matches(Self.probe(amount: 106_00), wide))
    let exact = Self.candidate(Self.item(tolerance: 0))
    #expect(!ScheduledMatch.matches(Self.probe(amount: 100_01), exact))
  }

  @Test("R-REC-6: day within ±3 days of the expected day")
  func days() {
    let c = Self.candidate(Self.item())
    #expect(ScheduledMatch.matches(Self.probe(day: "2026-03-13"), c))
    #expect(ScheduledMatch.matches(Self.probe(day: "2026-03-07"), c))
    #expect(!ScheduledMatch.matches(Self.probe(day: "2026-03-14"), c))
    #expect(!ScheduledMatch.matches(Self.probe(day: "2026-03-06"), c))
  }

  @Test("R-REC-6: other account, other type or direction, refunds and corrections never match")
  func accountAndDirection() {
    let c = Self.candidate(Self.item())
    #expect(!ScheduledMatch.matches(Self.probe(account: Self.other), c))
    #expect(!ScheduledMatch.matches(Self.probe(type: .income), c))
    let base = Txn(
      type: .expense, occurredAt: F.date("2026-03-10"), accountID: Self.account, amountMinor: 100_00, payee: "Gym Club")
    #expect(ScheduledMatch.probe(base, calendar: F.calendar) != nil)
    var refund = base
    refund.isRefund = true
    #expect(ScheduledMatch.probe(refund, calendar: F.calendar) == nil)
    var correction = base
    correction.isBalanceCorrection = true
    #expect(ScheduledMatch.probe(correction, calendar: F.calendar) == nil)
    var reversal = base
    reversal.type = .income
    reversal.isRefund = true
    #expect(ScheduledMatch.probe(reversal, calendar: F.calendar) == nil)
    // A transfer matches on its from-account only.
    let transfer = Txn(
      type: .transfer, occurredAt: F.date("2026-03-10"), accountID: Self.other, amountMinor: 100_00,
      toAccountID: Self.account, payee: "Gym Club")
    let probe = ScheduledMatch.probe(transfer, calendar: F.calendar)
    #expect(probe?.accountID == Self.other)
    #expect(!ScheduledMatch.matches(probe!, Self.candidate(Self.item(type: .transfer))))
  }

  @Test("R-REC-6: a description is compared only when both are non-empty")
  func descriptions() {
    let c = Self.candidate(Self.item())
    #expect(ScheduledMatch.matches(Self.probe(payee: ""), c))
    #expect(ScheduledMatch.matches(Self.probe(payee: "gym"), Self.candidate(Self.item(payee: ""))))
    #expect(!ScheduledMatch.matches(Self.probe(payee: "PIZZERIA ROMA"), c))
    #expect(ScheduledMatch.matches(Self.probe(payee: "Płatność GYM-CLUB 1234"), c))
  }

  @Test("R-REC-6: one transaction per occurrence; nearer day, then nearer amount wins")
  func competition() {
    // Two occurrences of a weekly-like pair compete for one transaction: the nearer day wins.
    let a = Self.item(100)
    let b = Self.item(101, start: "2026-03-12")
    let one = ScheduledMatch.assign([Self.probe(day: "2026-03-12", amount: 100_00)], to: [Self.candidate(a), Self.candidate(b, "2026-03-12")])
    #expect(one == [ScheduledAssignment(probeKey: "t", itemID: b.id, expectedDay: Day("2026-03-12")!)])

    // Same day gap: the nearer amount wins.
    let c = Self.item(102, amount: 103_00)
    let byAmount = ScheduledMatch.assign([Self.probe(amount: 102_50)], to: [Self.candidate(a), Self.candidate(c)])
    #expect(byAmount.map(\.itemID) == [c.id])

    // Two transactions, two occurrences: each gets one, nearest first.
    let both = ScheduledMatch.assign(
      [Self.probe("x", day: "2026-03-10"), Self.probe("y", day: "2026-03-12")], to: [Self.candidate(a), Self.candidate(b, "2026-03-12")])
    #expect(Set(both.map { "\($0.probeKey)\($0.itemID == a.id ? "a" : "b")" }) == ["xa", "yb"])

    // One occurrence, two transactions: only one takes it.
    let single = ScheduledMatch.assign([Self.probe("x", day: "2026-03-09"), Self.probe("y", day: "2026-03-10")], to: [Self.candidate(a)])
    #expect(single.map(\.probeKey) == ["y"])

    // Equal on everything: the older item (spec §4, two equal subscriptions).
    let older = Self.item(103, created: "2025-12-01")
    let tie = ScheduledMatch.assign([Self.probe()], to: [Self.candidate(a), Self.candidate(older)])
    #expect(tie.map(\.itemID) == [older.id])
  }
}

/// N5 steps 2–3 on the SQLite store: import preview and commit, manual save, launch sweep, undo
/// (R-REC-3, R-REC-7). Synthetic data.
@Suite("Scheduled matching on the store (R-REC-3, R-REC-7)")
struct ScheduledMatchStoreTests {
  typealias F = PipelineFixture
  typealias Env = PipelineIntegrationTests.Env

  let env: Env
  let scheduled: SQLiteScheduledStore

  init() throws {
    env = try Env()
    scheduled = SQLiteScheduledStore(database: env.database, calendar: F.calendar, now: { F.date("2026-03-01") })
  }

  /// Monthly "Grocery store" 9.99 on the PKO account from 24 Jan.
  static let grocery = ScheduledItem(
    id: F.id(100), type: .expense, accountID: F.pkoAccount.id, amountMinor: 9_99, payee: "Grocery store", unit: .month,
    startDay: "2026-01-24", createdAt: F.date("2026-01-01"))

  static func card(_ day: String, _ amount: String, _ merchant: String = "GROCERY STORE") -> String {
    #""\#(day)","\#(day)","Płatność kartą","-\#(amount)","PLN","+800.00","Tytuł: \#(day)","Lokalizacja: Adres: \#(merchant) Miasto: Kraków Kraj: POLSKA","","","","""#
  }

  func setUp(_ items: [ScheduledItem] = [grocery]) async throws {
    try await env.accounts.save(F.pkoAccount)
    for item in items { try await scheduled.save(item) }
  }

  func txnCount() async throws -> Int { try await env.allTxns().count }

  @Test("R-REC-7: the preview shows the match and counts it, writes nothing; the commit links; undo un-matches")
  func importFlow() async throws {
    try await setUp()
    let data = F.pko([Self.card("2026-01-25", "10.20"), Self.card("2026-01-26", "45.00", "PIZZERIA ROMA")])
    let preview = try await env.pipeline.preview(data: data, fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let matched = preview.rows.filter { $0.scheduledMatch != nil }
    #expect(matched.count == 1)
    #expect(preview.scheduledMatchCount == 1)
    let badge = try #require(matched.first?.scheduledMatch)
    #expect(badge.itemID == Self.grocery.id)
    #expect(badge.payee == "Grocery store")
    #expect(badge.expectedDay == Day("2026-01-24"))
    // Nothing written before the owner confirms.
    #expect(try await scheduled.occurrences(itemID: nil).isEmpty)
    #expect(try await txnCount() == 0)

    try await env.pipeline.commit(preview)
    let rows = try await scheduled.occurrences(itemID: Self.grocery.id)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.status == .paid)
    #expect(row.matchKind == .auto)
    #expect(row.expectedDay == "2026-01-24")
    #expect(row.actualAmountMinor == 10_20)
    let txn = try #require(try await env.allTxns().first { $0.txn.id == row.txnID })
    #expect(txn.txn.amountMinor == 10_20)

    // A second preview of a later statement does not offer the paid occurrence again.
    let again = try await env.pipeline.preview(
      data: F.pko([Self.card("2026-01-23", "9.99", "GROCERY STORE KRAKOW")]), fileName: "q.csv", targetAccountID: F.pkoAccount.id)
    #expect(again.scheduledMatchCount == 0)

    try await env.pipeline.undo(preview.batchID)
    #expect(try await scheduled.occurrences(itemID: nil).isEmpty)
  }

  @Test("R-REC-7: matching after a manual save; an edit keeps the link and refreshes the actuals; the transaction is unchanged")
  func manualSave() async throws {
    try await setUp()
    let txn = Txn(
      type: .expense, occurredAt: F.date("2026-02-23"), accountID: F.pkoAccount.id, amountMinor: 10_10, payee: "grocery store")
    try await env.txns.save(txn, lines: [])
    let before = try await env.txns.transaction(txn.id)
    let occurrence = try #require(try await scheduled.matchTransaction(txn.id, matcher: ScheduledMatch.rule))
    #expect(occurrence.expectedDay == "2026-02-24")
    #expect(occurrence.status == .paid)
    #expect(try await env.txns.transaction(txn.id) == before)

    var edited = txn
    edited.amountMinor = 20_00
    try await env.txns.save(edited, lines: [])
    let refreshed = try await scheduled.matchTransaction(txn.id, matcher: ScheduledMatch.rule)
    #expect(refreshed?.id == occurrence.id)
    #expect(refreshed?.actualAmountMinor == 20_00)

    // A transaction that matches nothing.
    let other = Txn(type: .expense, occurredAt: F.date("2026-02-10"), accountID: F.pkoAccount.id, amountMinor: 10_00)
    try await env.txns.save(other, lines: [])
    #expect(try await scheduled.matchTransaction(other.id, matcher: ScheduledMatch.rule) == nil)
  }

  @Test("R-REC-7, R-REC-9: the launch sweep matches, stores missed, ends finished items; running it again changes nothing")
  func sweep() async throws {
    var finite = Self.grocery
    finite = ScheduledItem(
      id: F.id(101), type: .income, accountID: F.pkoAccount.id, amountMinor: 5_000_00, payee: "Salary", unit: .month,
      startDay: "2026-01-10", endKind: .afterCount, endCount: 2, createdAt: F.date("2026-01-01"))
    try await setUp([Self.grocery, finite])
    // Paid by hand-typed transactions the editor did not match (abacus-import, MCP).
    let paid = Txn(type: .expense, occurredAt: F.date("2026-02-25"), accountID: F.pkoAccount.id, amountMinor: 9_99, payee: "")
    let salary = Txn(type: .income, occurredAt: F.date("2026-02-10"), accountID: F.pkoAccount.id, amountMinor: 5_000_00, payee: "SALARY FEB")
    try await env.txns.save(paid, lines: [])
    try await env.txns.save(salary, lines: [])

    let today = Day("2026-03-01")!
    let first = try await scheduled.sweep(today: today, matcher: ScheduledMatch.rule)
    #expect(first.matched == 2)
    // 24 Jan (grocery) and 10 Jan (salary) are past the 14-day grace and unpaid.
    #expect(first.missed == 2)
    #expect(first.ended == 1)
    let rows = try await scheduled.occurrences(itemID: nil)
    #expect(Set(rows.map { "\($0.expectedDay) \($0.status.rawValue)" }) == [
      "2026-01-24 missed", "2026-02-24 paid", "2026-01-10 missed", "2026-02-10 paid",
    ])
    #expect(try await scheduled.item(finite.id)?.status == .ended)

    let second = try await scheduled.sweep(today: today, matcher: ScheduledMatch.rule)
    #expect(second.isEmpty)
    #expect(try await scheduled.occurrences(itemID: nil).count == rows.count)

    // A late statement pays a missed occurrence.
    let late = Txn(type: .expense, occurredAt: F.date("2026-01-24"), accountID: F.pkoAccount.id, amountMinor: 9_99, payee: "Grocery")
    try await env.txns.save(late, lines: [])
    let third = try await scheduled.sweep(today: today, matcher: ScheduledMatch.rule)
    #expect(third.matched == 1)
    #expect(try await scheduled.occurrences(itemID: Self.grocery.id).allSatisfy { $0.status == .paid })
  }

  @Test("R-REC-3: no code path creates or changes a transaction; mode stays remind")
  func neverCreatesTransactions() async throws {
    try await setUp()
    let txn = Txn(type: .expense, occurredAt: F.date("2026-02-24"), accountID: F.pkoAccount.id, amountMinor: 9_99)
    try await env.txns.save(txn, lines: [])
    let before = try await env.allTxns()
    try await scheduled.sweep(today: Day("2026-06-30")!, matcher: ScheduledMatch.rule)
    try await scheduled.sweep(today: Day("2026-06-30")!, matcher: ScheduledMatch.rule)
    try await scheduled.skip(itemID: Self.grocery.id, expectedDay: Day("2026-07-24")!)
    #expect(try await env.allTxns() == before)
    #expect(try await scheduled.item(Self.grocery.id)?.mode == .remind)
    // Missed rows were stored for the unpaid months instead.
    #expect(try await scheduled.occurrences(itemID: nil).contains { $0.status == .missed })
  }

  @Test("R-REC-5, R-REC-7: the sweep pauses and resumes by archive state; an unlinked transaction is not matched again")
  func sweepArchiveAndUnlink() async throws {
    try await setUp()
    let txn = Txn(type: .expense, occurredAt: F.date("2026-02-24"), accountID: F.pkoAccount.id, amountMinor: 9_99)
    try await env.txns.save(txn, lines: [])
    let today = Day("2026-02-26")!
    // Archived outside the repository (a synced change): the sweep pauses the item.
    let accountID = F.pkoAccount.id
    try await env.database.write { db in try Account.find(accountID).update { $0.isArchived = true }.execute(db) }
    let paused = try await scheduled.sweep(today: today, matcher: ScheduledMatch.rule)
    #expect(paused.paused == 1)
    #expect(paused.matched == 0)
    #expect(try await scheduled.item(Self.grocery.id)?.pausedBecause == .accountArchived)

    try await env.database.write { db in try Account.find(accountID).update { $0.isArchived = false }.execute(db) }
    let resumed = try await scheduled.sweep(today: today, matcher: ScheduledMatch.rule)
    #expect(resumed.resumed == 1)
    #expect(resumed.matched == 1)

    let row = try #require(try await scheduled.occurrences(itemID: nil).first { $0.status == .paid })
    try await scheduled.reopen(row.id)
    let after = try await scheduled.sweep(today: today, matcher: ScheduledMatch.rule)
    #expect(after.matched == 0)
    #expect(try await scheduled.matchTransaction(txn.id, matcher: ScheduledMatch.rule) == nil)
    // Linking it by hand is still possible.
    try await scheduled.markPaid(itemID: Self.grocery.id, expectedDay: Day("2026-02-24")!, txnID: txn.id, kind: .linked)
  }
}
