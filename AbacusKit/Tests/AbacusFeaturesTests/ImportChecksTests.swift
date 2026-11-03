import AbacusDomain
import AbacusImport
import Foundation
import Testing

@testable import AbacusFeatures

/// N6: the Needs review sub-tabs for stale pending payments and balance gaps, their bulk actions,
/// selection by click / ⌘ click / ⇧ click, and the Reconcile offer after the import (R-CLR-8/9).
@MainActor
@Suite("Import checks (N6)")
struct ImportChecksTests {
  static let account = Account(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "PKO Personal", currency: .PLN, kind: .bank,
    openingBalanceMinor: 1_000_00,
    openingDate: ImportHarness.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!)

  static let header = #""Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","","""#

  static func csv(_ rows: [String]) -> Data {
    ([header] + rows).joined(separator: "\r\n").appending("\r\n").data(using: .windowsCP1250)!
  }

  static func hold(_ value: String, _ amount: String, _ merchant: String, ref: String) -> String {
    #""","\#(value)","Blokada","\#(amount)","PLN","W rozliczeniu","Tytuł: \#(ref)","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  static func card(_ day: String, _ amount: String, _ balance: String, _ merchant: String, ref: String) -> String {
    #""\#(day)","\#(day)","Płatność kartą","\#(amount)","PLN","\#(balance)","Tytuł: \#(ref)","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  /// Two holds imported earlier, then a statement booked 12.02 – 20.02 that mentions neither; its
  /// 15.02 row is missing (a balance gap).
  static func harnessWithHolds() async throws -> ImportHarness {
    let h = try await ImportHarness.empty(accounts: [account])
    await h.model.open(
      data: csv([hold("2026-02-10", "-23.40", "TAXI APP", ref: "H1"), hold("2026-02-11", "-12.00", "KIOSK", ref: "H2")]),
      fileName: "holds.csv")
    await h.model.chooseTargetAccount(account.id)
    h.model.acceptSuggestions()
    await h.model.commit()
    #expect(h.model.step == .done)
    await h.model.open(
      data: csv([
        card("2026-02-20", "-10.00", "+960.00", "BAKERY", ref: "L3"),
        card("2026-02-14", "-10.00", "+990.00", "SHOP", ref: "L1"),
        card("2026-02-12", "-5.00", "+1000.00", "KIOSK", ref: "L0"),
      ]),
      fileName: "later.csv")
    await h.model.chooseTargetAccount(account.id)
    return h
  }

  @Test("R-CLR-8: stale holds list in Pending payments, block Import until decided, count in the sub-tab and the tab")
  func staleListAndBlock() async throws {
    let h = try await Self.harnessWithHolds()
    let model = h.model
    #expect(model.staleItems.count == 2)
    #expect(model.reviewFilters.map(\.label).contains("Pending payments (2)"))
    #expect(model.reviewFilters.map(\.label).contains("Balance gaps (1)"))
    #expect(model.needsReviewTotal >= 3)
    #expect(!model.canCommit)
    #expect(model.blockingNote?.contains("2 pending payments not in the file still need a decision") == true)
    #expect(model.staleItems.allSatisfy { $0.choice == nil && $0.explanation.contains("days after this hold") })
    model.keepAllStale()
    #expect(model.staleItems.allSatisfy { $0.choice == .keep })
    #expect(model.undecidedStaleCount == 0)
  }

  @Test("R-CLR-8: click, ⌘ click and ⇧ click select stale holds; bulk Mark settled and Delete act on the selection")
  func selectionAndBulk() async throws {
    let h = try await Self.harnessWithHolds()
    let model = h.model
    model.tab = .review
    model.reviewFilter = .pending
    let ids = model.staleItems.map(\.id)
    #expect(model.selectableIDs == ids)
    model.select(ids[0], mode: .replace)
    #expect(model.selectedStaleIDs.count == 1)
    model.select(ids[1], mode: .range)
    #expect(model.selectedStaleIDs.count == 2)
    model.select(ids[0], mode: .toggle)
    #expect(model.selectedStaleIDs.count == 1)
    model.selectAll()
    model.setStale(.markSettled, ids: model.selectedStaleIDs)
    #expect(model.staleItems.allSatisfy { $0.choice == .markSettled })
    model.setStale(.delete, ids: [UUID(uuidString: ids[1])!])
    #expect(model.staleItems.map(\.choice) == [.markSettled, .delete])
    #expect(model.canCommit)
    await model.commit()
    #expect(model.step == .done)
    let rows = try await h.txns()
    #expect(rows.filter { $0.txn.payee.contains("TAXI") }.allSatisfy { !$0.txn.isPendingAtBank && !$0.txn.isCleared })
    #expect(!rows.contains { $0.txn.payee.contains("KIOSK") && $0.txn.isPendingAtBank })
  }

  @Test("R-CLR-8: Edit applies the inline values; the edited hold stays uncleared")
  func editHold() async throws {
    let h = try await Self.harnessWithHolds()
    let model = h.model
    let first = try #require(model.staleItems.first)
    let id = try #require(UUID(uuidString: first.id))
    model.setStale(.edit, ids: [id])
    model.updateStaleEdit(id) { $0.amountText = "25.00"; $0.stillPending = false }
    #expect(model.staleItems.first?.draft.amountText == "25.00" && model.staleItems.first?.choice == .edit)
    model.keepAllStale()
    model.setStale(.edit, ids: [id])
    await model.commit()
    let edited = try #require(try await h.txns().first { $0.txn.id == id }?.txn)
    #expect(edited.amountMinor == 25_00 && !edited.isPendingAtBank && !edited.isCleared)
  }

  @Test("R-CLR-9: balance gaps list with Leave and Remove per row; the footer says how many rows are removed; a start check line")
  func gaps() async throws {
    let h = try await Self.harnessWithHolds()
    let model = h.model
    model.keepAllStale()
    let gaps = model.gapItems
    // 14.02 ends on 990.00 but the 20.02 row starts from 970.00: rows of -20.00 are missing.
    #expect(gaps.count == 1)
    let gap = try #require(gaps.first)
    #expect(gap.before.balanceAfter.contains("990") && gap.after.startsFrom.contains("970"))
    #expect(!gap.before.isRemoved && !gap.after.isRemoved)
    model.setGapRow(gap.after.id, removed: true)
    #expect(model.gapItems.first?.after.isRemoved == true)
    #expect(model.footerNote.contains("1 row next to a balance gap will not be imported"))
    model.leaveAllGaps()
    #expect(model.gapItems.first?.after.isRemoved == false)
    #expect(model.canCommit)
  }

  @Test("R-CLR-5: after a PKO import the Done step offers Reconcile with the file's closing balance and day")
  func reconcileOffer() async throws {
    let h = try await Self.harnessWithHolds()
    h.model.keepAllStale()
    #expect(h.model.reconcileOffer == nil)
    await h.model.commit()
    let offer = try #require(h.model.reconcileOffer)
    #expect(offer.accountID == Self.account.id && offer.closingMinor == 960_00)
    #expect(offer.day == Day("2026-02-20"))
  }

  @Test("N6: a PKO file belongs to one account, so the Accounts & categories tab is not shown; Saldo keeps it")
  func mappingTab() async throws {
    let h = try await Self.harnessWithHolds()
    #expect(!h.model.tabs.contains { $0.tab == .mapping })
    let saldo = try await ImportHarness.empty()
    try await saldo.open("saldo", "spec-example")
    #expect(saldo.model.tabs.contains { $0.tab == .mapping })
  }
}
