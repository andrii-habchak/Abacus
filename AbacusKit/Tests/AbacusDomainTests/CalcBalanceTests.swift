import AbacusDomain
import Foundation
import Testing

@Suite("Calc: transaction effects and balances")
struct CalcBalanceTests {
  let card = Fx.account(1, .PLN, .card, opening: 1_000_00)
  let usd = Fx.account(2, .USD, .bank, opening: 500_00)
  let loan = Fx.account(3, .PLN, .loan, opening: -2_000_00)
  let groceries = Fx.category(10)
  let fees = Fx.category(11)
  let cashback = Fx.category(12, .income)

  @Test("R-TX-1: expense takes money out, income puts it in")
  func expenseAndIncome() {
    #expect(Calc.effects(of: Fx.expense(25_00, card, on: "2026-10-01")) == [AccountEffect(accountID: card.id, amountMinor: -25_00)])
    #expect(Calc.effects(of: Fx.income(80_00, card, on: "2026-10-01")) == [AccountEffect(accountID: card.id, amountMinor: 80_00)])
  }

  @Test("R-TX-4: an expense refund puts money back, an income reversal takes it out")
  func refunds() {
    #expect(Calc.effect(of: Fx.expense(25_00, card, on: "2026-10-01", refund: true), on: card.id) == 25_00)
    #expect(Calc.effect(of: Fx.income(80_00, card, on: "2026-10-01", reversal: true), on: card.id) == -80_00)
  }

  @Test("R-TX-5: a transfer moves the sent amount out and the received amount in")
  func transferBothSides() {
    let t = Fx.transfer(400_00, from: card, to: usd, received: 100_00, on: "2026-10-02")
    #expect(Calc.effects(of: t) == [
      AccountEffect(accountID: card.id, amountMinor: -400_00),
      AccountEffect(accountID: usd.id, amountMinor: 100_00),
    ])
  }

  @Test("R-TX-5: a same-currency transfer with one amount receives the sent amount")
  func transferSameCurrency() {
    let t = Fx.transfer(300_00, from: card, to: loan, on: "2026-10-02")
    #expect(Calc.effect(of: t, on: loan.id) == 300_00)
    #expect(Calc.effect(of: t, on: card.id) == -300_00)
  }

  @Test("R-TX-6: attached records hit the parent's account: main ± lines")
  func attachedRecords() {
    let t = Fx.expense(
      100_00, card, on: "2026-10-03", category: groceries,
      lines: [Fx.line(2_50, category: fees), Fx.line(1_00, .income, category: cashback)])
    #expect(Calc.effects(of: t) == [AccountEffect(accountID: card.id, amountMinor: -101_50)])
  }

  @Test("R-TX-6: a fee on a transfer hits the source account only")
  func transferFee() {
    let t = Fx.transfer(400_00, from: card, to: usd, received: 100_00, on: "2026-10-02", lines: [Fx.line(5_00, category: fees)])
    #expect(Calc.effect(of: t, on: card.id) == -405_00)
    #expect(Calc.effect(of: t, on: usd.id) == 100_00)
  }

  @Test("R-ACC-3: balance = opening balance + transaction effects, per account currency")
  func balances() {
    let txns = [
      Fx.expense(100_00, card, on: "2026-10-03", lines: [Fx.line(2_50)]),
      Fx.income(1_500_00, card, on: "2026-10-05"),
      Fx.expense(20_00, card, on: "2026-10-06", refund: true),
      Fx.transfer(400_00, from: card, to: usd, received: 100_00, on: "2026-10-07"),
      Fx.transfer(500_00, from: card, to: loan, on: "2026-10-08"),
    ]
    let result = Calc.balances(accounts: [card, usd, loan], txns: txns, calendar: Fx.calendar)
    #expect(result[card.id] == Money(minorUnits: 1_000_00 - 102_50 + 1_500_00 + 20_00 - 400_00 - 500_00, currency: .PLN))
    #expect(result[usd.id] == Money(minorUnits: 600_00, currency: .USD))
    #expect(result[loan.id] == Money(minorUnits: -1_500_00, currency: .PLN))
    #expect(Calc.balance(of: usd, txns: txns, calendar: Fx.calendar).minorUnits == 600_00)
  }

  @Test("R-ACC-3: a balance through a day ignores later transactions and a later opening")
  func balanceThroughDay() {
    let late = Fx.account(4, .PLN, opening: 70_00, openedOn: "2026-10-10")
    let txns = [
      Fx.income(10_00, card, on: "2026-09-30"),
      Fx.income(5_00, card, on: "2026-10-01"),
      Fx.income(1_00, late, on: "2026-10-12"),
    ]
    let atSep30 = Calc.balances(accounts: [card, late], txns: txns, through: Day("2026-09-30")!, calendar: Fx.calendar)
    #expect(atSep30[card.id]?.minorUnits == 1_010_00)
    #expect(atSep30[late.id]?.minorUnits == 0)
    let atOct31 = Calc.balances(accounts: [card, late], txns: txns, through: Day("2026-10-31")!, calendar: Fx.calendar)
    #expect(atOct31[late.id]?.minorUnits == 71_00)
  }
}
