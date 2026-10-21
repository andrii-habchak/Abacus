import AbacusDomain
import AbacusImport
import Foundation
import Testing

@Suite("Rule matching shared by imports, editor and tester")
struct RulesConsistencyTests {
  let groceries = AbacusDomain.Category(name: "Groceries", kind: .expense)
  let salary = AbacusDomain.Category(name: "Salary", kind: .income)

  @Test("R-IMP-8, R-EDIT-3: matching ignores case, diacritics and extra spaces")
  func folding() {
    let rule = CategoryRule(pattern: "Żabka  Nano", categoryID: groceries.id)
    let matcher = RuleMatcher(rules: [rule], categories: [groceries])
    #expect(matcher.match(description: "ZABKA nano 0042 WARSZAWA", accountID: nil, kind: .expense) == rule)
    #expect(matcher.match(description: "zabka", accountID: nil, kind: .expense) == nil)
  }

  @Test("R-IMP-8: the tester's \"any account\" lets a per-account rule match; a wrong kind never does")
  func testerSemantics() {
    let account = UUID()
    let scoped = CategoryRule(pattern: "orlen", accountID: account, categoryID: groceries.id)
    #expect(RuleMatcher.matches(scoped, description: "ORLEN 12", accountID: nil, categories: [groceries]))
    #expect(RuleMatcher.matches(scoped, description: "ORLEN 12", accountID: account, categories: [groceries]))
    #expect(!RuleMatcher.matches(scoped, description: "ORLEN 12", accountID: UUID(), categories: [groceries]))
    let disabled = CategoryRule(pattern: "orlen", categoryID: groceries.id, isEnabled: false)
    #expect(!RuleMatcher.matches(disabled, description: "ORLEN", accountID: nil, categories: [groceries]))
    let archived = AbacusDomain.Category(id: salary.id, name: "Salary", kind: .income, isArchived: true)
    let toArchived = CategoryRule(pattern: "acme", categoryID: salary.id)
    #expect(!RuleMatcher.matches(toArchived, description: "ACME payroll", accountID: nil, categories: [archived]))
  }
}
