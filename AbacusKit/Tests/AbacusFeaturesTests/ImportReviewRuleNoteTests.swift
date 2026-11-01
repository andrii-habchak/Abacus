import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// C46: the rule line on Needs review cards for every reason a rule can express (the owner saw
/// none on "Transfer to an own account in another currency"), the bulk "Save rules" sheet, the
/// rule saved on import and used by the next import. Synthetic PKO rows: a PLN account receives
/// money from the owner's USD account (found by its number) and an unknown operation type.
@MainActor
struct ImportReviewRuleNoteTests {
  private static let pln = Account(
    id: PreviewData.id(9701), name: "PKO PLN", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")
  private static let usd = Account(
    id: PreviewData.id(9702), name: "PKO USD", currency: .USD, kind: .bank, openingBalanceMinor: 500_00,
    openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "55 5555 5555 5555 5555 5555 5555")
  private static let salary = AbacusDomain.Category(id: PreviewData.id(9710), name: "Salary", kind: .income)
  private static let taxes = AbacusDomain.Category(id: PreviewData.id(9711), name: "Taxes", kind: .expense)

  private struct Rates: CurrencyConverter {
    func rate(from: Currency, to: Currency, on day: Day) -> Decimal? {
      if from == to { return 1 }
      if from == .USD, to == .PLN { return 4 }
      if from == .PLN, to == .USD { return Decimal(string: "0.25") }
      return nil
    }
    func latestRate(from: Currency, to: Currency) -> Decimal? { rate(from: from, to: to, on: Day("2026-03-01")!) }
    var latestDay: Day? { Day("2026-03-01")! }
  }

  private static let header =
    #""Data operacji","Data waluty","Typ transakcji","Kwota","Waluta","Saldo po transakcji","Opis transakcji","","","","","""#

  private static func file(_ rows: [String]) -> Data {
    (([header] + rows).joined(separator: "\r\n") + "\r\n").data(using: .windowsCP1250)!
  }

  /// Money in from the own USD account: the USD amount is unknown.
  private static func plnIn(_ day: String, _ amount: String, ref: String) -> String {
    #""\#(day)","\#(day)","Przelew na konto","+\#(amount)","PLN","+100.00","Rachunek nadawcy: 55 5555 5555 5555 5555 5555 5555","Nazwa nadawcy: JAN PRZYKLAD","Tytuł: NA WLASNY KOSZT \#(ref)","","","""#
  }

  /// An unknown PKO operation type (money in or out by its sign).
  private static func unknown(_ day: String, _ amount: String, _ title: String) -> String {
    #""\#(day)","\#(day)","Operacja specjalna","\#(amount)","PLN","+1000.00","Tytuł: \#(title)","","","","","""#
  }

  private func database() async throws -> any DatabaseWriter {
    let database = try AbacusDatabase.open(at: nil)
    let accounts = SQLiteAccountRepository(database: database, calendar: ImportHarness.calendar)
    try await accounts.save(Self.pln)
    try await accounts.save(Self.usd)
    let categories = SQLiteCategoryRepository(database: database)
    try await categories.save(Self.salary)
    try await categories.save(Self.taxes)
    return database
  }

  private func model(_ database: any DatabaseWriter, _ rows: [String]) async -> ImportWizardModel {
    let model = ImportWizardModel(
      dependencies: .live(
        database: database, calendar: ImportHarness.calendar, now: { ImportHarness.now }, converter: { Rates() }))
    await model.load()
    await model.open(data: Self.file(rows), fileName: "pko.csv")
    if model.needsTargetAccount { await model.chooseTargetAccount(Self.pln.id) }
    model.tab = .review
    return model
  }

  private func rules(_ database: any DatabaseWriter) async throws -> [CategoryRule] {
    try await SQLiteRuleRepository(database: database).rules()
  }

  @Test("transfer to an own account in another currency: the card shows the rule line once the other side is given; Don't save turns it off")
  func transferCardShowsRule() async throws {
    let database = try await database()
    let model = await model(database, [Self.plnIn("2026-03-10", "400.00", ref: "1")])
    let card = try #require(model.reviewItems.first)
    #expect(card.title == "Transfer to an own account in another currency")
    #expect(card.ruleNote == nil)
    // The account found by its number is pre-filled (not the first account A–Z).
    #expect(card.selectedTransferAccount == Self.usd.id)

    model.selectReviewOption(.transfer, forRow: card.id)
    #expect(model.counterpartPicker?.accountID == Self.usd.id)
    model.useEstimatedCounterpart()
    let resolved = try #require(model.reviewItems.first)
    #expect(resolved.selected == .transfer)
    #expect(resolved.ruleNote == ImportNote("Will be saved as a rule “jan przyklad” → Transfer to PKO USD", .info))
    #expect(resolved.savesRule == true)
    #expect(model.footerNote.contains("1 new rule will be saved"))

    model.setSavesRule(false, forRow: card.id)
    #expect(model.reviewItems.first?.ruleNote == ImportNote("Not saved as a rule"))
    #expect(model.reviewItems.first?.savesRule == false)
    model.setSavesRule(true, forRow: card.id)

    await model.commit()
    let saved = try await rules(database)
    #expect(saved.count == 1)
    #expect(saved.first?.action == .transfer && saved.first?.transferAccountID == Self.usd.id)

    // The next import: the card is back (the USD amount is unknown again), with the rule's
    // suggestion marked and its account pre-filled; confirming it opens the other side sheet.
    let next = await self.model(database, [Self.plnIn("2026-04-10", "800.00", ref: "2")])
    let again = try #require(next.reviewItems.first)
    #expect(again.selected == nil)
    #expect(again.suggested == .transfer)
    #expect(again.selectedTransferAccount == Self.usd.id)
    #expect(again.ruleNote == ImportNote("Suggested by rule “jan przyklad”", .success))
    next.selectReviewOption(.transfer, forRow: again.id)
    #expect(next.counterpartPicker?.accountID == Self.usd.id)
    next.useEstimatedCounterpart()
    #expect(next.reviewItems.first?.ruleNote == ImportNote("By rule “jan przyklad”"))
    #expect(next.reviewItems.first?.savesRule == nil)
  }

  @Test("unknown type: Expense without a category hints at the rule, a category shows the rule line")
  func unknownTypeCard() async throws {
    let database = try await database()
    let model = await model(database, [Self.unknown("2026-03-10", "-120.00", "ZAKŁAD UBEZPIECZEŃ SPOŁECZNYCH")])
    let card = try #require(model.reviewItems.first)
    #expect(card.suggested == .record(.expense))
    model.acceptSuggestions()
    #expect(model.reviewItems.first?.selected == .record(.expense))
    #expect(model.reviewItems.first?.ruleNote == ImportNote("Choose a category to save it as a rule"))
    model.selectReviewCategory(Self.taxes.id, forRow: card.id)
    #expect(model.reviewItems.first?.ruleNote == ImportNote("Will be saved as a rule “zaklad ubezpieczen spolecznych” → Taxes", .info))
    #expect(model.reviewItems.first?.savesRule == true)
    model.selectReviewOption(.skip, forRow: card.id)
    #expect(model.reviewItems.first?.ruleNote == nil)
  }

  @Test("bulk Category over cards of different reasons lists every rule in the Save rules sheet")
  func bulkCategorySheet() async throws {
    let database = try await database()
    let model = await model(
      database, [Self.plnIn("2026-03-10", "400.00", ref: "1"), Self.unknown("2026-03-11", "+50.00", "ZWROT SKLADKI")])
    let ids = model.reviewItems.map(\.id)
    try #require(ids.count == 2)
    model.reviewFilter = .decisions
    model.selectAll()
    model.bulkSetCategory(Self.salary.id, kind: .income)
    let sheet = try #require(model.ruleSheet)
    #expect(Set(sheet.suggestions.map(\.pattern)) == ["jan przyklad", "zwrot skladki"])
    #expect(sheet.suggestions.allSatisfy { $0.categoryName == "Salary" })
    model.applyRuleSheet()
    #expect(model.reviewItems.allSatisfy { $0.savesRule == true })
    await model.commit()
    #expect(Set(try await rules(database).map(\.pattern)) == ["jan przyklad", "zwrot skladki"])
  }
}
