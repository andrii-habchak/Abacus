import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// C32: a category rule acts only on rows of its category's kind, and a debt rule whose debt is
/// gone is skipped. Synthetic data only.
@Suite("Rule kind and stale debt (C32)")
struct RuleKindAndDebtTests {
  typealias F = PipelineFixture

  static let expenseRule = CategoryRule(id: F.id(301), pattern: "acme", categoryID: F.groceries.id, position: 0)
  static let incomeRule = CategoryRule(id: F.id(302), pattern: "acme", categoryID: F.salary.id, position: 1)
  static let categories = [F.groceries, F.salary]

  @Test("R-IMP-8, C32: an income-category rule applies to income rows only, an expense-category rule to expense rows only")
  func kindSelectsRule() {
    let matcher = RuleMatcher(rules: [Self.expenseRule, Self.incomeRule], categories: Self.categories)
    let income = RuleSubject(description: "ACME payout", amountMinor: 10_00, kind: .income)
    let expense = RuleSubject(description: "ACME shop", amountMinor: 10_00, kind: .expense)
    #expect(matcher.match(income)?.id == Self.incomeRule.id)
    #expect(matcher.match(expense)?.id == Self.expenseRule.id)
    // Alone, each rule ignores rows of the other kind.
    #expect(RuleMatcher(rules: [Self.incomeRule], categories: Self.categories).match(expense) == nil)
    #expect(RuleMatcher(rules: [Self.expenseRule], categories: Self.categories).match(income) == nil)
  }

  @Test("R-MGMT-6, C32: updating existing transactions leaves rows of the other kind alone")
  func kindOnExisting() {
    let account = F.pkoAccount
    let income = Txn(type: .income, occurredAt: F.date("2026-01-10"), accountID: account.id, amountMinor: 10_00, payee: "Acme payout")
    let expense = Txn(type: .expense, occurredAt: F.date("2026-01-11"), accountID: account.id, amountMinor: 10_00, payee: "Acme shop")
    let items = [income, expense].map { TxnWithLines(txn: $0, lines: []) }
    let changes = RuleEffect.changes(Self.incomeRule, in: items, accounts: [account], categories: Self.categories)
    #expect(changes.map(\.id) == [income.id] && changes.first?.categoryID == F.salary.id)
    let other = RuleEffect.changes(Self.expenseRule, in: items, accounts: [account], categories: Self.categories)
    #expect(other.map(\.id) == [expense.id])
  }

  @Test("R-DEBT-12, C32: a debt rule is skipped when its debt was renamed or deleted, and works while it exists")
  func staleDebtSkipped() {
    let rule = CategoryRule(id: F.id(303), pattern: "anna", action: .debt, debtPersonName: "Anna", position: 0)
    let subject = RuleSubject(description: "Transfer Anna", amountMinor: 10_00, kind: .expense)
    let anna = Debt(personName: "Anna")
    let live = DebtBook(debts: [anna])
    #expect(RuleMatcher(rules: [rule], categories: [], debts: live).match(subject)?.id == rule.id)
    // Case and accents do not matter, like everywhere else for a person.
    let shouting = CategoryRule(id: F.id(304), pattern: "anna", action: .debt, debtPersonName: " ANNA ", position: 0)
    #expect(RuleMatcher(rules: [shouting], categories: [], debts: live).match(subject) != nil)
    // Renamed or deleted: no match, so the next rule gets its turn.
    let renamed = DebtBook(debts: [Debt(personName: "Hanna")])
    let fallback = CategoryRule(id: F.id(305), pattern: "anna", categoryID: F.groceries.id, position: 1)
    let matcher = RuleMatcher(rules: [rule, fallback], categories: Self.categories, debts: renamed)
    #expect(matcher.match(subject)?.id == fallback.id)
    #expect(RuleMatcher(rules: [rule], categories: [], debts: .empty).match(subject) == nil)
    // Unchecked (no book given): as before.
    #expect(RuleMatcher(rules: [rule], categories: []).match(subject)?.id == rule.id)
  }

  @Test("R-DEBT-12, C32: Update existing transactions skips a debt rule whose debt is gone")
  func staleDebtOnExisting() {
    let account = F.pkoAccount
    let txn = Txn(type: .expense, occurredAt: F.date("2026-01-11"), accountID: account.id, amountMinor: 10_00, payee: "Transfer Anna")
    let items = [TxnWithLines(txn: txn, lines: [])]
    let rule = CategoryRule(pattern: "anna", action: .debt, debtPersonName: "Anna")
    #expect(RuleEffect.changes(rule, in: items, accounts: [account], categories: []).isEmpty)
    let book = DebtBook(debts: [Debt(personName: "Anna")])
    #expect(RuleEffect.changes(rule, in: items, accounts: [account], categories: [], debts: book).count == 1)
  }
}
