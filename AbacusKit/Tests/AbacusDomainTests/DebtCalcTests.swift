import AbacusDomain
import Foundation
import Testing

@Suite("Debt calculators (C14)")
struct DebtCalcTests {
  @Test("R-DEBT-3: a transfer without destination moves money out, or in with isRefund")
  func oneSidedLegs() {
    let account = UUID()
    let out = Txn(type: .transfer, occurredAt: Date(), accountID: account, amountMinor: 5_00)
    var inflow = out
    inflow.isRefund = true
    #expect(Calc.mainEffects(of: out) == [AccountEffect(accountID: account, amountMinor: -5_00)])
    #expect(Calc.mainEffects(of: inflow) == [AccountEffect(accountID: account, amountMinor: 5_00)])
    #expect(inflow.isOneSidedInflow && !out.isOneSidedInflow)
    // A two-sided transfer ignores isRefund as before.
    var twoSided = inflow
    twoSided.toAccountID = UUID()
    #expect(Calc.mainEffects(of: twoSided).first?.amountMinor == -5_00)
  }

  @Test("R-DEBT-2, R-DEBT-4: kinds move the balance and offer flags as the TA says")
  func kinds() {
    #expect(DebtRecordKind.allCases.filter { $0.balanceSign > 0 } == [.lent, .iRepaid, .paidOnTheirBehalf, .forgivenByThem])
    #expect(DebtRecordKind.allCases.filter { !$0.movesMoney } == [.forgaveThem, .forgivenByThem])
    #expect(DebtRecordKind.allCases.filter(\.isInflow) == [.theyRepaid, .borrowed])
    #expect(DebtRecordKind.allCases.filter { $0.offeredReportKind == .expense } == [.lent, .paidOnTheirBehalf, .forgaveThem])
    #expect(DebtRecordKind.allCases.filter { $0.offeredReportKind == .income } == [.theyRepaid])
    #expect(DebtRecordKind.allCases.filter(\.reportsByDefault) == [.forgaveThem])
  }

  @Test("R-DEBT-2: balance through a day")
  func balanceThroughDay() {
    let debt = Debt(personName: "Person A", currency: .PLN)
    let records = [
      DebtRecord(debtID: debt.id, kind: .lent, day: "2026-01-10", amountMinor: 100_00),
      DebtRecord(debtID: debt.id, kind: .theyRepaid, day: "2026-02-10", amountMinor: 30_00),
      DebtRecord(debtID: debt.id, kind: .forgaveThem, day: "2026-03-10", amountMinor: 70_00),
    ]
    #expect(Calc.debtBalance(debt, records: records).minorUnits == 0)
    #expect(Calc.debtBalance(debt, records: records, through: Day("2026-02-28")!).minorUnits == 70_00)
    #expect(Calc.debtBalance(debt, records: records, through: Day("2026-01-09")!).minorUnits == 0)
  }
}
