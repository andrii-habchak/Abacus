import AbacusDomain
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// N5 step 1: scheduled items, occurrences and dismissals in the store (synthetic data).
@Suite("Scheduled items store (R-REC-1, R-REC-5, R-REC-16)")
struct ScheduledStoreTests {
  let fixture: StoreFixture
  let store: SQLiteScheduledStore

  init() throws {
    fixture = try StoreFixture()
    try fixture.seedBasics()
    store = SQLiteScheduledStore(database: fixture.database, calendar: StoreFixture.calendar)
  }

  static func rent(
    id: Int = 100, account: Account = StoreFixture.bank, start: String = "2026-03-10", endKind: ScheduleEndKind = .never,
    endCount: Int? = nil
  ) -> ScheduledItem {
    ScheduledItem(
      id: StoreFixture.id(id), type: .expense, accountID: account.id, amountMinor: 1_500_00,
      categoryID: StoreFixture.fees.id, payee: "Flat rent", unit: .month, startDay: start, endKind: endKind,
      endCount: endCount, createdAt: StoreFixture.at("2026-03-01"))
  }

  static var today: Day { Day(Date(), calendar: StoreFixture.calendar) }

  // MARK: R-REC-1

  @Test("R-REC-1: every field round trips; mode is remind; items listed oldest first")
  func roundTrip() async throws {
    let item = ScheduledItem(
      id: StoreFixture.id(101), type: .transfer, accountID: StoreFixture.bank.id, toAccountID: StoreFixture.card.id,
      amountMinor: 400_00, toAmountMinor: 90_00, eventID: StoreFixture.trip.id, payee: "Card top-up", note: "n",
      unit: .month, interval: 2, startDay: "2026-01-31", lastDayOfMonth: true, endKind: .onDay, endDay: "2027-01-31",
      tolerancePercent: 8, createdAt: StoreFixture.at("2026-01-02"))
    try await store.save(item)
    try await store.save(Self.rent())
    #expect(try await store.item(item.id) == item)
    #expect(try await store.items().map(\.id) == [item.id, Self.rent().id])
    #expect(try await store.item(item.id)?.mode == .remind)
  }

  @Test("R-REC-1: validation (amount, every N, end before start, transfer accounts)")
  func validation() async throws {
    var item = Self.rent()
    item.interval = 0
    await #expect(throws: ScheduledError.self) { try await store.save(item) }
    item = Self.rent()
    item.amountMinor = 0
    await #expect(throws: ScheduledError.self) { try await store.save(item) }
    item = Self.rent()
    item.endKind = .onDay
    item.endDay = "2026-01-01"
    await #expect(throws: ScheduledError.self) { try await store.save(item) }
    item = Self.rent()
    item.type = .transfer
    item.toAccountID = item.accountID
    await #expect(throws: ScheduledError.self) { try await store.save(item) }
    #expect(try await store.items().isEmpty)
  }

  @Test("R-REC-1: pause and resume by the owner; deleting an item keeps its occurrences and transactions")
  func pauseAndDelete() async throws {
    let item = Self.rent()
    try await store.save(item)
    let txn = StoreFixture.expense(1, "2026-03-10", 1_500_00, StoreFixture.fees, payee: "Flat rent")
    try await fixture.insert(txn)
    try await store.markPaid(itemID: item.id, expectedDay: Day("2026-03-10")!, txnID: txn.id, kind: .linked)

    try await store.setPaused(item.id, true, today: Self.today)
    #expect(try await store.item(item.id)?.status == .paused)
    #expect(try await store.item(item.id)?.pausedBecause == .owner)
    try await store.setPaused(item.id, false, today: Day("2026-03-11")!)
    #expect(try await store.item(item.id)?.status == .active)
    #expect(try await store.item(item.id)?.pausedBecause == nil)

    try await store.delete(item.id)
    #expect(try await store.item(item.id) == nil)
    #expect(try await store.occurrences(itemID: item.id).count == 1)
    #expect(try await fixture.txns.transaction(txn.id) != nil)
    await #expect(throws: RepositoryError.notFound) { try await store.delete(item.id) }
  }

  // MARK: R-REC-5

  @Test("R-REC-5: archiving pauses (Account archived), unarchiving resumes only those")
  func archive() async throws {
    let start = Self.today.string
    let onBank = Self.rent(id: 100, start: start)
    var ownerPaused = Self.rent(id: 101, start: start)
    ownerPaused.status = .paused
    ownerPaused.pausedBecause = .owner
    var transferIn = Self.rent(id: 102, account: StoreFixture.card, start: start)
    transferIn.type = .transfer
    transferIn.toAccountID = StoreFixture.bank.id
    for item in [onBank, ownerPaused, transferIn] { try await store.save(item) }

    try await fixture.accounts.setArchived(StoreFixture.bank.id, true)
    var byID = Dictionary(uniqueKeysWithValues: try await store.items().map { ($0.id, $0) })
    #expect(byID[onBank.id]?.status == .paused)
    #expect(byID[onBank.id]?.pausedBecause == .accountArchived)
    #expect(byID[ownerPaused.id]?.pausedBecause == .owner)
    #expect(byID[transferIn.id]?.pausedBecause == .accountArchived)

    // The owner cannot resume it while the account is archived; a new item there starts paused.
    try await store.setPaused(onBank.id, false, today: Self.today)
    #expect(try await store.item(onBank.id)?.status == .paused)
    try await store.save(Self.rent(id: 103, start: start))
    #expect(try await store.item(StoreFixture.id(103))?.pausedBecause == .accountArchived)

    try await fixture.accounts.setArchived(StoreFixture.bank.id, false)
    byID = Dictionary(uniqueKeysWithValues: try await store.items().map { ($0.id, $0) })
    #expect(byID[onBank.id]?.status == .active)
    #expect(byID[transferIn.id]?.status == .active)
    #expect(byID[ownerPaused.id]?.status == .paused)
    #expect(byID[ownerPaused.id]?.pausedBecause == .owner)
  }

  @Test("R-REC-5: unarchiving does not report the archived period as missed (stored as skipped)")
  func unarchiveGap() async throws {
    let item = Self.rent(start: Self.today.plusDays(-70).string)
    try await store.save(item)
    try await fixture.accounts.setArchived(StoreFixture.bank.id, true)
    try await fixture.accounts.setArchived(StoreFixture.bank.id, false)
    let rows = try await store.occurrences(itemID: item.id)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.status == .skipped })
    #expect(rows.allSatisfy { Day($0.expectedDay)! < Self.today.plusDays(-ScheduledOccurrences.defaultGraceDays) })
  }

  @Test("R-REC-5: an account with scheduled items keeps its currency; deleting it deletes its items")
  func currencyAndDelete() async throws {
    let empty = Account(
      id: StoreFixture.id(9), name: "Spare", currency: .PLN, kind: .bank, openingBalanceMinor: 0,
      openingDate: StoreFixture.at("2026-01-01"))
    try await fixture.accounts.save(empty)
    var item = Self.rent(account: empty)
    item.type = .transfer
    item.toAccountID = StoreFixture.bank.id
    try await store.save(item)
    let txn = StoreFixture.expense(1, "2026-03-10", 1_500_00, nil)
    try await fixture.insert(txn)
    try await store.skip(itemID: item.id, expectedDay: Day("2026-04-10")!)

    var changed = empty
    changed.currency = .EUR
    await #expect(throws: StoreError.currencyLocked) { try await fixture.accounts.save(changed) }

    try await fixture.accounts.delete(empty.id)
    #expect(try await store.items().isEmpty)
    #expect(try await store.occurrences(itemID: item.id).count == 1)
    // Without items the currency of another empty account can change again.
    try await fixture.accounts.save(changed)
  }

  // MARK: Occurrences (R-REC-3, R-REC-4)

  @Test("R-REC-3: identity (item, day) is guarded; one transaction per occurrence")
  func identity() async throws {
    let item = Self.rent()
    try await store.save(item)
    let a = StoreFixture.expense(1, "2026-03-10", 1_500_00, nil)
    let b = StoreFixture.expense(2, "2026-03-11", 1_500_00, nil)
    try await fixture.insert(a)
    try await fixture.insert(b)
    let march = Day("2026-03-10")!
    let april = Day("2026-04-10")!

    await #expect(throws: ScheduledError.notAnOccurrence) {
      try await store.markPaid(itemID: item.id, expectedDay: Day("2026-03-11")!, txnID: a.id, kind: .linked)
    }
    try await store.skip(itemID: item.id, expectedDay: march)
    let paid = try await store.markPaid(itemID: item.id, expectedDay: march, txnID: a.id, kind: .linked)
    #expect(paid.status == .paid)
    #expect(paid.actualAmountMinor == 1_500_00)
    #expect(paid.actualDay == "2026-03-10")
    #expect(try await store.occurrences(itemID: item.id).count == 1)
    // Again with the same transaction: no second row.
    try await store.markPaid(itemID: item.id, expectedDay: march, txnID: a.id, kind: .linked)
    #expect(try await store.occurrences(itemID: item.id).count == 1)
    await #expect(throws: ScheduledError.occurrenceAlreadyPaid) {
      try await store.markPaid(itemID: item.id, expectedDay: march, txnID: b.id, kind: .linked)
    }
    await #expect(throws: ScheduledError.transactionAlreadyLinked) {
      try await store.markPaid(itemID: item.id, expectedDay: april, txnID: a.id, kind: .linked)
    }
    await #expect(throws: ScheduledError.occurrenceAlreadyPaid) { try await store.skip(itemID: item.id, expectedDay: march) }
    #expect(try await store.resolvedKeys() == [OccurrenceKey(itemID: item.id, day: march)])
    // The transaction is untouched.
    #expect(try await fixture.txns.transaction(a.id)?.txn == a)
  }

  @Test("R-REC-3: synced duplicates of one identity read as one and collapse on the next write")
  func syncDuplicates() async throws {
    let item = Self.rent()
    try await store.save(item)
    try await fixture.database.write { db in
      for n in 0..<2 {
        try ScheduledOccurrence.insert {
          ScheduledOccurrence(
            itemID: item.id, expectedDay: "2026-03-10", expectedAmountMinor: 1_500_00, status: .skipped,
            resolvedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)))
        }.execute(db)
      }
    }
    #expect(try await store.resolvedKeys().count == 1)
    let txn = StoreFixture.expense(1, "2026-03-10", 1_500_00, nil)
    try await fixture.insert(txn)
    try await store.markPaid(itemID: item.id, expectedDay: Day("2026-03-10")!, txnID: txn.id, kind: .typed)
    let rows = try await store.occurrences(itemID: item.id)
    #expect(rows.count == 1)
    #expect(rows.first?.matchKind == .typed)
  }

  @Test("R-REC-4: reopen returns an occurrence to expected; a deleted transaction does too")
  func reopenAndDelete() async throws {
    let item = Self.rent()
    try await store.save(item)
    let a = StoreFixture.expense(1, "2026-03-10", 1_500_00, nil)
    let b = StoreFixture.expense(2, "2026-04-10", 1_500_00, nil)
    try await fixture.insert(a)
    try await fixture.insert(b)
    let paid = try await store.markPaid(itemID: item.id, expectedDay: Day("2026-03-10")!, txnID: a.id, kind: .auto)
    try await store.markPaid(itemID: item.id, expectedDay: Day("2026-04-10")!, txnID: b.id, kind: .auto)

    try await store.reopen(paid.id)
    #expect(try await store.occurrences(itemID: item.id).map(\.expectedDay) == ["2026-04-10"])
    // The unlink marker is not a dismissed suggestion.
    #expect(try await store.dismissals().isEmpty)

    try await fixture.txns.delete(b.id)
    #expect(try await store.occurrences(itemID: item.id).isEmpty)
  }

  @Test("R-REC-1: an item ends when its last occurrence is resolved and is active again when reopened")
  func endsAfterLast() async throws {
    let item = Self.rent(endKind: .afterCount, endCount: 2)
    try await store.save(item)
    try await store.skip(itemID: item.id, expectedDay: Day("2026-03-10")!)
    #expect(try await store.item(item.id)?.status == .active)
    let last = try await store.skip(itemID: item.id, expectedDay: Day("2026-04-10")!)
    #expect(try await store.item(item.id)?.status == .ended)
    try await store.reopen(last.id)
    #expect(try await store.item(item.id)?.status == .active)
  }

  // MARK: R-REC-16

  @Test("R-REC-16: a dismissal persists per (account, key), once, and can be restored")
  func dismissals() async throws {
    let key = "netflix|expense|PLN"
    try await store.dismiss(accountID: StoreFixture.bank.id, key: key)
    try await store.dismiss(accountID: StoreFixture.bank.id, key: key)
    try await store.dismiss(accountID: StoreFixture.card.id, key: key)
    let rows = try await store.dismissals()
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.accountID)) == [StoreFixture.bank.id, StoreFixture.card.id])
    // A second store over the same database sees them (persisted).
    let again = SQLiteScheduledStore(database: fixture.database)
    let bank = try #require(try await again.dismissals().first { $0.accountID == StoreFixture.bank.id })
    try await again.restore(bank.id)
    #expect(try await store.dismissals().map(\.accountID) == [StoreFixture.card.id])
    await #expect(throws: RepositoryError.notFound) { try await store.restore(bank.id) }
  }
}
