import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// N6: pending holds that the file should have settled and did not (R-CLR-8).
@Suite("Stale pending holds (N6)")
struct StaleHoldsTests {
  typealias F = PipelineFixture

  private func card(_ value: String, _ booked: String, _ amount: String, _ balance: String, _ merchant: String, ref: String) -> String {
    #""\#(booked)","\#(value)","Płatność kartą","\#(amount)","PLN","\#(balance)","Tytuł: \#(ref)","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  private func hold(_ value: String, _ amount: String, _ merchant: String, ref: String) -> String {
    #""","\#(value)","Blokada","\#(amount)","PLN","W rozliczeniu","Tytuł: \#(ref)","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  /// A database with one hold (value day 2026-02-10) from an earlier import.
  private func dbWithHold() async throws -> (FakeDB, Txn) {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    var first = try await db.pipeline().preview(data: F.pko([hold("2026-02-10", "-23.40", "TAXI APP", ref: "H1")]), fileName: "a.csv", targetAccountID: F.pkoAccount.id)
    first.acceptSuggestedReviewChoices()
    _ = try await db.pipeline().commit(first)
    return (db, try #require(db.txns.first))
  }

  private func later(lastBooked: String, extra: [String] = []) -> Data {
    // Booked rows from 2026-02-12 to `lastBooked`; balances chain from 1000.00.
    F.pko(
      extra + [
        card(lastBooked, lastBooked, "-10.00", "+980.00", "BAKERY", ref: "L2"),
        card("2026-02-12", "2026-02-12", "-10.00", "+990.00", "KIOSK", ref: "L1"),
      ].reversed().reversed())
  }

  @Test("R-CLR-8: a hold 5 or more days before the file's last booked day, covered by the file and matched by no row, is stale")
  func raised() async throws {
    let (db, taxi) = try await dbWithHold()
    let preview = try await db.pipeline().preview(data: later(lastBooked: "2026-02-15"), fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    #expect(preview.staleHolds.map(\.id) == [taxi.id])
    #expect(preview.staleHolds[0].daysBehind == 5)
    #expect(!preview.canCommit)
    #expect(preview.undecidedStaleHolds.count == 1)
  }

  @Test("R-CLR-8: 4 days is not stale; a hold before the file's first booked day minus 3 is out of reach")
  func boundaries() async throws {
    let (db, _) = try await dbWithHold()
    let four = try await db.pipeline().preview(data: later(lastBooked: "2026-02-14"), fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    #expect(four.staleHolds.isEmpty && four.canCommit)
    // First booked day 2026-02-20: the hold of 02-10 is more than 3 days before it.
    let far = F.pko([
      card("2026-02-25", "2026-02-25", "-10.00", "+980.00", "BAKERY", ref: "L2"),
      card("2026-02-20", "2026-02-20", "-10.00", "+990.00", "KIOSK", ref: "L1"),
    ])
    let outOfReach = try await db.pipeline().preview(data: far, fileName: "c.csv", targetAccountID: F.pkoAccount.id)
    #expect(outOfReach.staleHolds.isEmpty)
  }

  @Test("R-CLR-8: a hold the file settles, or lists again, is not raised; another account's hold is not either")
  func notRaised() async throws {
    let (db, taxi) = try await dbWithHold()
    let settles = F.pko([
      card("2026-02-20", "2026-02-20", "-10.00", "+980.00", "BAKERY", ref: "L2"),
      card("2026-02-10", "2026-02-12", "-23.40", "+990.00", "TAXI APP", ref: "S1"),
    ])
    let settled = try await db.pipeline().preview(data: settles, fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    #expect(settled.counts.settlesPending == 1 && settled.staleHolds.isEmpty)

    let relisted = F.pko([
      hold("2026-02-10", "-23.40", "TAXI APP", ref: "H1"),
      card("2026-02-20", "2026-02-20", "-10.00", "+980.00", "BAKERY", ref: "L2"),
      card("2026-02-12", "2026-02-12", "-10.00", "+990.00", "KIOSK", ref: "L1"),
    ])
    let again = try await db.pipeline().preview(data: relisted, fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    #expect(again.staleHolds.isEmpty)

    // The same hold on another account is not this account's business.
    var other = FakeDB()
    other.accounts = [F.pkoAccount]
    other.txns = [Txn(type: .expense, occurredAt: taxi.occurredAt, accountID: F.id(99), amountMinor: 23_40, source: .pko, isPendingAtBank: true)]
    let none = try await other.pipeline().preview(data: later(lastBooked: "2026-02-20"), fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    #expect(none.staleHolds.isEmpty)
    // A Saldo-sourced pending row never counts.
    other = FakeDB()
    other.accounts = [F.pkoAccount]
    other.txns = [Txn(type: .expense, occurredAt: taxi.occurredAt, accountID: F.pkoAccount.id, amountMinor: 23_40, source: .saldo, isPendingAtBank: true)]
    let saldo = try await other.pipeline().preview(data: later(lastBooked: "2026-02-20"), fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    #expect(saldo.staleHolds.isEmpty)
  }

  @Test("R-CLR-8: Keep all decides at once; defaults keep; Delete, Mark settled and Edit commit and are counted")
  func decisions() async throws {
    let (db, taxi) = try await dbWithHold()
    var preview = try await db.pipeline().preview(data: later(lastBooked: "2026-02-15"), fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    #expect(preview.acceptingDefaults().canCommit)  // headless: kept
    #expect(preview.acceptingDefaults().staleHoldDecision(taxi.id) == .keep)

    preview.setStaleHold(.delete, for: [taxi.id])
    #expect(preview.canCommit && preview.undecidedStaleHolds.isEmpty)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.staleDeleted == 1)
    #expect(summary.lines.contains { $0.contains("1 pending payment not in the file: 1 deleted") })
    #expect(summary.batch.summary.contains("1 stale hold"))
    #expect(!db.txns.contains { $0.id == taxi.id })
    #expect(db.commits.last?.deletedTxns.map(\.id) == [taxi.id])
  }

  @Test("R-CLR-8: Mark settled stops the hold being pending and leaves it uncleared; Edit keeps it uncleared; Keep changes nothing")
  func settleEditKeep() async throws {
    for choice in ["settle", "edit", "keep"] {
      let (db, taxi) = try await dbWithHold()
      var preview = try await db.pipeline().preview(data: later(lastBooked: "2026-02-15"), fileName: "b.csv", targetAccountID: F.pkoAccount.id)
      switch choice {
      case "settle": preview.setStaleHold(.markSettled, for: [taxi.id])
      case "edit": preview.setStaleHold(.edit(StaleHoldEdit(amountMinor: 25_00, day: Day("2026-02-09")!, stillPending: false)), for: [taxi.id])
      default: preview.setStaleHold(.keep, for: [taxi.id])
      }
      let summary = try await db.pipeline().commit(preview)
      let after = try #require(db.txns.first { $0.id == taxi.id })
      #expect(!after.isCleared)
      switch choice {
      case "settle":
        #expect(!after.isPendingAtBank && after.amountMinor == 23_40 && summary.staleSettled == 1)
        #expect(db.commits.last?.flagOriginals.map(\.id) == [taxi.id])
      case "edit":
        #expect(!after.isPendingAtBank && after.amountMinor == 25_00 && Day(after.occurredAt, calendar: F.calendar) == Day("2026-02-09"))
        #expect(summary.staleEdited == 1)
      default:
        #expect(after.isPendingAtBank && after == taxi && summary.staleKept == 1)
      }
    }
  }

  @Test("R-CLR-8: a history line records 0 stale holds for a file without any")
  func zero() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let preview = try await db.pipeline().preview(data: later(lastBooked: "2026-02-15"), fileName: "b.csv", targetAccountID: F.pkoAccount.id)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.batch.summary.contains("0 stale holds") && summary.batch.summary.contains("0 balance gaps"))
  }
}
