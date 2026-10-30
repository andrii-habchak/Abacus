import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// C36: an unknown PKO operation type is mapped by an enabled category rule of the right kind
/// instead of waiting in Needs review. Synthetic data only.
@Suite("Unknown operation type and rules (C36)")
struct UnknownTypeRuleTests {
  typealias F = PipelineFixture

  private func row(_ amount: String, _ title: String) -> String {
    #""2026-02-10","2026-02-10","Operacja specjalna","\#(amount)","PLN","+1000.00","Tytuł: \#(title)","","","","","""#
  }

  private func preview(rules: [CategoryRule], rows: [String]) async throws -> ImportPreview {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.categories = [F.groceries, F.salary]
    db.rules = rules
    return try await db.pipeline().preview(data: F.pko(rows), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
  }

  @Test("an enabled income rule resolves an unknown incoming row as income by the rule")
  func incomeRuleResolves() async throws {
    let rule = CategoryRule(id: F.id(401), pattern: "deel", categoryID: F.salary.id)
    let preview = try await preview(rules: [rule], rows: [row("+100.00", "DEEL PAYROLL")])
    let resolved = try #require(preview.rows.first)
    #expect(resolved.review == nil)
    #expect(resolved.status == .new)
    #expect(resolved.type == .income)
    #expect(resolved.category == .existing(F.salary.id))
    #expect(resolved.categorySource == .rule(rule.id, pattern: "deel"))
    #expect(resolved.createsTransaction)
    #expect(preview.counts.needsReview == 0)
    #expect(preview.unresolvedReviewCount == 0)
  }

  @Test("an expense rule resolves an unknown outgoing row")
  func expenseRuleResolves() async throws {
    let rule = CategoryRule(id: F.id(402), pattern: "deel", categoryID: F.groceries.id)
    let preview = try await preview(rules: [rule], rows: [row("-30.00", "DEEL FEE")])
    let resolved = try #require(preview.rows.first)
    #expect(resolved.review == nil)
    #expect(resolved.type == .expense)
    #expect(resolved.category == .existing(F.groceries.id))
  }

  @Test("a rule of the wrong kind does not resolve the row")
  func wrongKind() async throws {
    let expenseRule = CategoryRule(id: F.id(403), pattern: "deel", categoryID: F.groceries.id)
    let a = try await preview(rules: [expenseRule], rows: [row("+100.00", "DEEL PAYROLL")])
    #expect(a.rows.first?.review?.reason == .unknownOperationType)
    #expect(a.counts.needsReview == 1)
    let incomeRule = CategoryRule(id: F.id(404), pattern: "deel", categoryID: F.salary.id)
    let b = try await preview(rules: [incomeRule], rows: [row("-30.00", "DEEL FEE")])
    #expect(b.rows.first?.review?.reason == .unknownOperationType)
  }

  @Test("a disabled rule, no rule or a rule for other text leaves the row in review")
  func disabledAndMissing() async throws {
    let disabled = CategoryRule(id: F.id(405), pattern: "deel", categoryID: F.salary.id, isEnabled: false)
    let a = try await preview(rules: [disabled], rows: [row("+100.00", "DEEL PAYROLL")])
    #expect(a.rows.first?.review?.reason == .unknownOperationType)
    let b = try await preview(rules: [], rows: [row("+100.00", "DEEL PAYROLL")])
    #expect(b.rows.first?.review?.reason == .unknownOperationType)
    let other = CategoryRule(id: F.id(406), pattern: "other", categoryID: F.salary.id)
    let c = try await preview(rules: [other], rows: [row("+100.00", "DEEL PAYROLL")])
    #expect(c.rows.first?.review != nil)
  }

  @Test("an account-scoped rule resolves only rows of its account")
  func accountScoped() async throws {
    let mine = CategoryRule(id: F.id(407), pattern: "deel", accountID: F.pkoAccount.id, categoryID: F.salary.id)
    let a = try await preview(rules: [mine], rows: [row("+100.00", "DEEL PAYROLL")])
    #expect(a.rows.first?.review == nil)
    let elsewhere = CategoryRule(id: F.id(408), pattern: "deel", accountID: F.id(999), categoryID: F.salary.id)
    let b = try await preview(rules: [elsewhere], rows: [row("+100.00", "DEEL PAYROLL")])
    #expect(b.rows.first?.review?.reason == .unknownOperationType)
  }

  @Test("a resolved row commits as income with the category; other unknown rows stay in review")
  func commits() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.categories = [F.groceries, F.salary]
    db.rules = [CategoryRule(id: F.id(409), pattern: "deel", categoryID: F.salary.id)]
    let data = F.pko([row("+100.00", "DEEL PAYROLL"), row("+5.00", "SOMETHING ELSE")])
    let preview = try await db.pipeline().preview(data: data, fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    #expect(preview.counts.needsReview == 1)
    #expect(preview.rows.filter { $0.review != nil }.map(\.source.payee) == ["SOMETHING ELSE"])
    var ready = preview
    ready.acceptSuggestedReviewChoices()
    try await db.pipeline().commit(ready)
    let payroll = try #require(db.txns.first { $0.payee.contains("DEEL") })
    #expect(payroll.type == .income)
    #expect(payroll.categoryID == F.salary.id)
  }
}
