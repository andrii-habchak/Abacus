import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// Categorisation rules: applying and learning (R-IMP-8, R-EDIT-3).
@Suite("Import rules")
struct RulesTests {
  typealias F = PipelineFixture

  private let food = AbacusDomain.Category(id: F.id(60), name: "Food", kind: .expense)
  private let archived = AbacusDomain.Category(id: F.id(61), name: "Old", kind: .expense, isArchived: true)

  private func rule(_ n: Int, _ pattern: String, _ category: AbacusDomain.Category, account: Account.ID? = nil, enabled: Bool = true) -> CategoryRule {
    CategoryRule(id: F.id(100 + n), pattern: pattern, accountID: account, categoryID: category.id, position: n, isEnabled: enabled)
  }

  // MARK: Matcher

  @Test("R-IMP-8: first match in order, case-insensitive contains")
  func firstMatch() {
    let matcher = RuleMatcher(
      rules: [rule(0, "Grocery", F.groceries), rule(1, "store", food)],
      categories: [F.groceries, food])
    #expect(matcher.match(description: "GROCERY  STORE 12", accountID: nil, kind: .expense)?.categoryID == F.groceries.id)
    #expect(matcher.match(description: "Book store", accountID: nil, kind: .expense)?.categoryID == food.id)
    #expect(matcher.match(description: "Cinema", accountID: nil, kind: .expense) == nil)
    #expect(matcher.match(description: "", accountID: nil, kind: .expense) == nil)
  }

  @Test("R-IMP-8: account-scoped rules apply to their account only; kind, disabled and archived rules are skipped")
  func scopeAndFilters() {
    let matcher = RuleMatcher(
      rules: [
        rule(0, "taxi", F.taxi, account: F.pkoAccount.id),
        rule(1, "taxi", food, enabled: false),
        rule(2, "taxi", archived),
        rule(3, "taxi", F.salary),
        rule(4, "taxi", F.groceries),
      ],
      categories: [F.taxi, food, archived, F.salary, F.groceries])
    #expect(matcher.match(description: "TAXI APP", accountID: F.pkoAccount.id, kind: .expense)?.categoryID == F.taxi.id)
    #expect(matcher.match(description: "TAXI APP", accountID: F.pkoUSD.id, kind: .expense)?.categoryID == F.groceries.id)
    #expect(matcher.match(description: "TAXI APP", accountID: nil, kind: .income)?.categoryID == F.salary.id)
  }

  @Test("R-IMP-8: a learned pattern is the first words without digits")
  func derivePattern() {
    #expect(RulePattern.derive(from: "GROCERY  STORE 0042 WARSZAWA") == "grocery store")
    #expect(RulePattern.derive(from: "0042 Coffee kiosk") == "coffee kiosk")
    #expect(RulePattern.derive(from: "www.shop.example") == "www.shop.example")
    #expect(RulePattern.derive(from: "X 12") == "")
    #expect(RulePattern.derive(from: "City Hall Market Street") == "city hall market")
    #expect(RulePattern.derive(from: "12345") == "")
  }

  // MARK: In the pipeline

  @Test("R-IMP-8: existing rules categorise imported rows; the file's category wins for Saldo")
  func appliedInPreview() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.categories = [F.groceries, F.taxi, food]
    db.rules = [rule(0, "taxi app", F.taxi), rule(1, "cafe", food)]
    var preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let taxi = try #require(preview.rows.first { $0.source.payee == "TAXI APP" })
    #expect(taxi.category == .existing(F.taxi.id))
    #expect(taxi.categorySource == .rule(F.id(100), pattern: "taxi app"))
    #expect(taxi.rulePattern == nil)
    let atm = try #require(preview.rows.first { $0.type == .transfer })
    #expect(atm.categorySource == .notApplicable)
    #expect(preview.uncategorisedCount == 9)
    preview.acceptSuggestedReviewChoices()
    try await db.pipeline().commit(preview)
    #expect(db.rules.first { $0.id == F.id(100) }?.hitCount == 1)

    let saldo = try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "s.csv")
    let cafe = try #require(saldo.row("saldo:1002"))
    #expect(cafe.categorySource == .file)
    #expect(cafe.category == .new(key: "expense|Eating out"))
  }

  @Test("R-IMP-8: a category picked for an uncategorised row is learned and applied to similar rows")
  func learnedFromChoice() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.categories = [F.groceries, food]
    var preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let coffees = preview.rows.filter { $0.source.payee == "COFFEE KIOSK" }
    #expect(coffees.count == 2)
    #expect(coffees.allSatisfy { $0.needsCategory })
    let uncategorised = preview.uncategorisedCount

    preview.setCategory(food.id, forRow: coffees[0].id)
    let picked = try #require(preview.row(coffees[0].id))
    #expect(picked.categorySource == .user)
    #expect(picked.rulePattern == "coffee kiosk")
    let other = try #require(preview.row(coffees[1].id))
    #expect(other.category == .existing(food.id))
    #expect(other.categorySource == .learnedRule(pattern: "coffee kiosk"))
    #expect(preview.rulesToSave == [RuleProposal(pattern: "coffee kiosk", categoryID: food.id, rowCount: 2)])
    #expect(preview.uncategorisedCount == uncategorised - 2)

    // Opting out keeps the pick but saves no rule.
    preview.setSavesRule(false, forRow: coffees[0].id)
    #expect(preview.rulesToSave.isEmpty)
    #expect(preview.row(coffees[1].id)?.category == nil)
    preview.setSavesRule(true, forRow: coffees[0].id)

    preview.acceptSuggestedReviewChoices()
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.rulesSaved == 1)
    let saved = try #require(db.rules.first)
    #expect(saved.pattern == "coffee kiosk")
    #expect(saved.origin == .imported)
    #expect(saved.accountID == nil)
    #expect(saved.hitCount == 2)
    #expect(db.txns.filter { $0.categoryID == food.id }.count == 2)

    // The next statement is categorised by the saved rule.
    let next = try await db.pipeline().preview(
      data: F.pko([
        #""2026-01-20","2026-01-19","Płatność kartą","-4.50","PLN","+900.00","Tytuł: 77","Lokalizacja: Adres: COFFEE KIOSK Miasto: Kraków Kraj: POLSKA","","","","""#
      ]), fileName: "p2.csv", targetAccountID: F.pkoAccount.id)
    #expect(next.rows[0].categorySource == .rule(saved.id, pattern: "coffee kiosk"))
  }

  @Test("R-IMP-8: a pick on a row that a rule or the file already categorised saves no rule")
  func noRuleForOverrides() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    db.categories = [F.groceries, F.taxi, food]
    db.rules = [rule(0, "taxi", F.taxi)]
    var preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let taxi = try #require(preview.rows.first { $0.source.payee == "TAXI APP" })
    preview.setCategory(food.id, forRow: taxi.id)
    #expect(preview.row(taxi.id)?.category == .existing(food.id))
    #expect(preview.rulesToSave.isEmpty)
    preview.resetCategory(forRow: taxi.id)
    #expect(preview.row(taxi.id)?.category == .existing(F.taxi.id))

    let saldo = try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "s.csv")
    var s = saldo
    s.setCategory(food.id, forRow: "saldo:1002")
    #expect(s.rulesToSave.isEmpty)
  }
}
