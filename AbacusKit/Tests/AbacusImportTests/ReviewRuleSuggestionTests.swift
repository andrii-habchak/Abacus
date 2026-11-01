import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// C42: resolving an "Unknown operation type" card offers a rule like a category pick does.
/// Synthetic data only.
@Suite("Rules from review resolutions (C42)")
struct ReviewRuleSuggestionTests {
  typealias F = PipelineFixture

  static let savings = Account(
    id: F.id(3), name: "Savings", currency: .PLN, kind: .bank, openingDate: F.date("2026-01-01", 0))

  private func row(_ amount: String, _ title: String) -> String {
    #""2026-02-10","2026-02-10","Operacja specjalna","\#(amount)","PLN","+1000.00","Tytuł: \#(title)","","","","","""#
  }

  private func preview(_ rows: [String], rules: [CategoryRule] = []) async throws -> (ImportPreview, FakeDB) {
    let db = FakeDB()
    db.accounts = [F.pkoAccount, Self.savings]
    db.categories = [F.groceries, F.salary]
    db.rules = rules
    let preview = try await db.pipeline().preview(data: F.pko(rows), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    return (preview, db)
  }

  @Test("record with a category: a category rule is proposed and saved on commit")
  func recordWithCategory() async throws {
    var (preview, db) = try await preview([row("-30.00", "DEEL FEE 0042")])
    let id = try #require(preview.rows.first).id
    preview.setReviewChoice(.record(.expense, categoryID: F.groceries.id), forRow: id)
    let resolved = try #require(preview.row(id))
    #expect(resolved.rulePattern == "deel fee")
    #expect(resolved.learnedAction == .category(F.groceries.id))
    #expect(preview.rulesToSave == [RuleProposal(pattern: "deel fee", categoryID: F.groceries.id, rowCount: 1)])
    try await db.pipeline().commit(preview)
    let rule = try #require(db.rules.first)
    #expect(rule.action == .category && rule.categoryID == F.groceries.id && rule.pattern == "deel fee")
  }

  @Test("transfer to an own account: a transfer rule is proposed and saved")
  func transferRule() async throws {
    var (preview, db) = try await preview([row("-30.00", "DEEL FEE")])
    let id = try #require(preview.rows.first).id
    preview.setReviewChoice(.transfer(accountID: Self.savings.id), forRow: id)
    #expect(preview.rulesToSave == [RuleProposal(pattern: "deel fee", action: .transfer(Self.savings.id), rowCount: 1)])
    try await db.pipeline().commit(preview)
    let rule = try #require(db.rules.first)
    #expect(rule.action == .transfer && rule.transferAccountID == Self.savings.id && rule.categoryID == nil)
  }

  @Test("transfer to a debt: a debt rule is proposed and saved")
  func debtRule() async throws {
    var (preview, db) = try await preview([row("-30.00", "DEEL FEE")])
    let id = try #require(preview.rows.first).id
    preview.setReviewChoice(.debt(ImportDebtChoice(personName: "Ann", currency: .PLN)), forRow: id)
    #expect(preview.rulesToSave == [RuleProposal(pattern: "deel fee", action: .debt(person: "Ann"), rowCount: 1)])
    try await db.pipeline().commit(preview)
    let rule = try #require(db.rules.first)
    #expect(rule.action == .debt && rule.debtPersonName == "Ann")
  }

  @Test("skip, a record without category, a record of the other kind and an open card propose nothing")
  func notExpressible() async throws {
    var (preview, _) = try await preview([row("-30.00", "DEEL FEE")])
    let id = try #require(preview.rows.first).id
    #expect(preview.rulesToSave.isEmpty)
    preview.setReviewChoice(.skip, forRow: id)
    #expect(preview.rulesToSave.isEmpty && preview.row(id)?.learnedAction == nil)
    preview.setReviewChoice(.record(.expense, categoryID: nil), forRow: id)
    #expect(preview.rulesToSave.isEmpty)
    preview.setReviewChoice(.record(.income, categoryID: F.salary.id), forRow: id)
    #expect(preview.rulesToSave.isEmpty)
  }

  @Test("turning the rule off keeps the choice but saves no rule; turning it on restores it")
  func toggle() async throws {
    var (preview, db) = try await preview([row("-30.00", "DEEL FEE")])
    let id = try #require(preview.rows.first).id
    preview.setReviewChoice(.transfer(accountID: Self.savings.id), forRow: id)
    preview.setSavesRule(false, forRow: id)
    #expect(preview.rulesToSave.isEmpty)
    #expect(preview.row(id)?.learnedAction == .transfer(Self.savings.id))
    #expect(preview.row(id)?.rulePattern == nil)
    preview.setRulePattern("deel", forRow: id)
    preview.setSavesRule(true, forRow: id)
    #expect(preview.rulesToSave.map(\.pattern) == ["deel"])
    try await db.pipeline().commit(preview)
    #expect(db.rules.count == 1)
  }

  @Test("no rule is proposed when an enabled rule already matches the text")
  func existingRule() async throws {
    // A rule of the other kind does not resolve the row, so it stays in review; the matching
    // transfer rule is not duplicated.
    let existing = CategoryRule(id: F.id(501), pattern: "deel", action: .transfer, transferAccountID: Self.savings.id)
    let (a, _) = try await preview([row("-30.00", "DEEL FEE")], rules: [existing])
    #expect(a.rows.first?.review == nil)
    #expect(a.rulesToSave.isEmpty)
  }

  @Test("a learned rule resolves the next unknown row of the same payee")
  func learnedRuleResolvesNextTime() async throws {
    var (first, db) = try await preview([row("-30.00", "DEEL FEE")])
    let id = try #require(first.rows.first).id
    first.setReviewChoice(.transfer(accountID: Self.savings.id), forRow: id)
    try await db.pipeline().commit(first)
    let second = try await db.pipeline().preview(
      data: F.pko([row("-12.00", "DEEL FEE 7")]), fileName: "p2.csv", targetAccountID: F.pkoAccount.id)
    let resolved = try #require(second.rows.first)
    #expect(resolved.review == nil)
    #expect(resolved.type == .transfer)
    #expect(resolved.counterAccount == .existing(Self.savings.id))
  }
}
