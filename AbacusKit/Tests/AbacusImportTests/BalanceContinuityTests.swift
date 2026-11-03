import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// N6: the balance chain of a PKO file (R-CLR-9). Synthetic statements only.
@Suite("Balance continuity (N6)")
struct BalanceContinuityTests {
  typealias F = PipelineFixture

  private func card(_ booked: String, _ amount: String, _ balance: String, ref: String, merchant: String = "SHOP") -> String {
    #""\#(booked)","\#(booked)","Płatność kartą","\#(amount)","PLN","\#(balance)","Tytuł: \#(ref)","Lokalizacja: Adres: \#(merchant) Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  private func hold(_ value: String, _ amount: String, ref: String) -> String {
    #""","\#(value)","Blokada","\#(amount)","PLN","W rozliczeniu","Tytuł: \#(ref)","Lokalizacja: Adres: HOLD SHOP Miasto: Warszawa Kraj: POLSKA","","","","""#
  }

  private func analyze(_ rows: [String]) throws -> BalanceContinuity {
    let parsed = try PKOParser(account: F.pkoAccount, calendar: F.calendar).parse(F.pko(rows))
    return BalanceContinuity.analyze(parsed.rows, calendar: F.calendar)
  }

  // Start 1040.00: -30 → 1010, -20 → 990, -10 → 980 (a row per day, newest first in the file).
  private var rowOne: String { card("2026-02-02", "-30.00", "+1010.00", ref: "A1") }
  private var rowTwo: String { card("2026-02-03", "-20.00", "+990.00", ref: "A2") }
  private var rowThree: String { card("2026-02-04", "-10.00", "+980.00", ref: "A3") }

  @Test("R-CLR-9: balances that chain give no gap, the file's start and end")
  func healthy() throws {
    let result = try analyze([rowThree, rowTwo, rowOne])
    #expect(result.gaps.isEmpty)
    #expect(result.startMinor == 1040_00 && result.startDay == Day("2026-02-02"))
    #expect(result.endMinor == 980_00 && result.endDay == Day("2026-02-04"))
  }

  @Test("R-CLR-9: a missing day is one gap with the signed missing amount between the rows around it")
  func oneGap() throws {
    let result = try analyze([rowThree, rowOne])
    #expect(result.gaps.count == 1)
    let gap = try #require(result.gaps.first)
    #expect(gap.missingMinor == -20_00)
    #expect(gap.before.payee == "SHOP" && gap.before.bookedDay == Day("2026-02-02") && gap.before.balanceAfterMinor == 1010_00)
    #expect(gap.after.bookedDay == Day("2026-02-04") && gap.after.startsFromMinor == 990_00)
    #expect(result.startMinor == 1040_00 && result.endMinor == 980_00)
  }

  @Test("R-CLR-9: two gaps are listed oldest first")
  func twoGaps() throws {
    let rows = [
      card("2026-02-06", "-5.00", "+950.00", ref: "B5"), card("2026-02-05", "-10.00", "+955.00", ref: "B4"),
      rowThree, rowOne,
    ]
    // 980 → (missing +20 and so on) the row of 02-05 starts from 965: a gap of -15 after 980.
    let result = try analyze(rows)
    #expect(result.gaps.map(\.missingMinor) == [-20_00, -15_00])
    #expect(result.gaps[0].before.bookedDay < result.gaps[1].before.bookedDay)
  }

  @Test("R-CLR-9: rows of one day in any order, equal balances and zero amounts still chain")
  func sameDayAndEquals() throws {
    // Start 1000: +50 → 1050, -50 → 1000, 0 → 1000 on one day; then -10 → 990 next day.
    let day = "2026-02-02"
    let rows = [
      card("2026-02-03", "-10.00", "+990.00", ref: "C4"),
      card(day, "+0.00", "+1000.00", ref: "C3"),
      card(day, "-50.00", "+1000.00", ref: "C2"),
      card(day, "+50.00", "+1050.00", ref: "C1"),
    ]
    let result = try analyze(rows)
    #expect(result.gaps.isEmpty)
    #expect(result.startMinor == 1000_00 && result.endMinor == 990_00)
    // Same rows, file order reversed.
    #expect(try analyze(Array(rows.reversed())).gaps.isEmpty)
  }

  @Test("R-CLR-9: holds have no balance and are ignored; a one-row file has no gap")
  func holdsAndSingle() throws {
    let result = try analyze([hold("2026-02-03", "-12.00", ref: "H1"), rowOne])
    #expect(result.gaps.isEmpty && result.startMinor == 1040_00 && result.endMinor == 1010_00)
    #expect(try analyze([hold("2026-02-03", "-12.00", ref: "H1")]) == .empty)
  }

  @Test("R-CLR-9: the preview carries the gaps and removing a row next to a gap skips it, without blocking the commit")
  func previewGap() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    var preview = try await db.pipeline().preview(data: F.pko([rowThree, rowOne]), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    #expect(preview.continuity.gaps.count == 1)
    #expect(preview.canCommit)
    let gap = preview.continuity.gaps[0]
    preview.setGapRow(gap.after.id, removed: true)
    #expect(preview.gapRowsRemoved == 1)
    #expect(preview.counts.skipped >= 1)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.created == 1 && summary.balanceGaps == 1 && summary.gapRowsRemoved == 1)
    #expect(summary.batch.summary.contains("1 balance gap"))
    #expect(db.txns.count == 1)
  }

  @Test("R-CLR-9: the file's start is compared with the account's cleared balance; a Saldo file has no check")
  func startCheck() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let preview = try await db.pipeline().preview(data: F.pko([rowThree, rowTwo, rowOne]), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    // The fake store has no cleared balances: no check on a first import.
    #expect(preview.startCheck == nil)
    let saldo = try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "s.csv")
    #expect(saldo.continuity == .empty && saldo.staleHolds.isEmpty)
  }
}
