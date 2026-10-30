import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// C18: a person's records on several accounts (R-DEBT-14) and the display-currency switch on
/// the Debts tab (R-DEBT-15). Synthetic data only (`DebtSample`, `PreviewData`).
@MainActor
@Suite("Debts: several accounts and the currency switch (C18)")
struct DebtsCurrencyTests {
  nonisolated static let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)

  static func loadedModel(_ currency: Currency = .UAH) async throws -> DebtsModel {
    let database = try DebtSample.database()
    let dependencies = DebtsDependencies(
      debts: SQLiteDebtRepository(database: database), accounts: SQLiteAccountRepository(database: database),
      converter: { rates }, today: { PreviewData.today })
    let model = DebtsModel(dependencies: dependencies)
    model.displayCurrency = currency
    await model.load()
    return model
  }

  static func select(_ name: String, in model: DebtsModel) throws {
    model.selectedPerson = try #require(model.people.first { $0.name == name }).id
  }

  @Test("Calc.debtAccountFlows: money out and in per account, in the account's currency; no-account records left out")
  func accountFlowsCalc() {
    let euro = Debt(personName: "Pat Test", currency: .EUR)
    let zloty = Debt(personName: "Pat Test", currency: .PLN)
    let other = Debt(personName: "Other", currency: .EUR)
    let a = UUID()
    let b = UUID()
    func entry(_ debt: Debt, _ kind: DebtRecordKind, _ amount: Int64, leg: (UUID, Int64)?) -> DebtRecordEntry {
      let record = DebtRecord(debtID: debt.id, kind: kind, day: "2026-10-01", amountMinor: amount)
      let txn = leg.map { Txn(type: .transfer, occurredAt: Date(), accountID: $0.0, amountMinor: $0.1) }
      return DebtRecordEntry(record: record, leg: txn)
    }
    let book = DebtBook(
      debts: [euro, zloty, other],
      entries: [
        entry(euro, .lent, 100_00, leg: (a, 100_00)),
        entry(euro, .lent, 20_00, leg: (b, 900_00)),  // EUR debt paid from a UAH account
        entry(euro, .theyRepaid, 30_00, leg: (a, 30_00)),
        entry(zloty, .borrowed, 50_00, leg: (b, 480_00)),
        entry(euro, .forgaveThem, 10_00, leg: nil),
        entry(other, .lent, 999_00, leg: (a, 999_00)),
      ])
    let flows = Calc.debtAccountFlows(book, debtIDs: [euro.id, zloty.id])
    #expect(flows.map(\.accountID) == [a, b])
    #expect(flows[0].outMinor == 100_00 && flows[0].inMinor == 30_00 && flows[0].records == 2)
    #expect(flows[1].outMinor == 900_00 && flows[1].inMinor == 480_00 && flows[1].records == 2)
  }

  @Test("R-DEBT-14: the person's detail lists every account used, out/in in the account's currency, and each record's account")
  func perAccountSummary() async throws {
    let model = try await Self.loadedModel()
    try Self.select("Alex Example", in: model)
    let flows = model.selectedAccountFlows
    // EUR debt via Revolut and Monobank (UAH), PLN debt via PKO.
    #expect(Set(flows.map(\.id)) == [PreviewData.revolutEUR.id, PreviewData.monobank.id, PreviewData.pkoPersonal.id])
    #expect(flows.map(\.name) == flows.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    let format = model.format
    let revolut = try #require(flows.first { $0.id == PreviewData.revolutEUR.id })
    #expect(revolut.currency == .EUR)
    #expect(revolut.outText == "−" + format.money(Money(minorUnits: 380_00, currency: .EUR)))
    #expect(revolut.inText == "+" + format.money(Money(minorUnits: 120_00, currency: .EUR)))
    #expect(revolut.recordsText == "3 records")
    let mono = try #require(flows.first { $0.id == PreviewData.monobank.id })
    #expect(mono.currency == .UAH && mono.inText == nil)
    #expect(mono.outText == "−" + format.money(Money(minorUnits: 2_400_00, currency: .UAH)))
    let pko = try #require(flows.first { $0.id == PreviewData.pkoPersonal.id })
    #expect(pko.outText == nil && pko.inText == "+" + format.money(Money(minorUnits: 250_00, currency: .PLN)))

    // Every record names its account; the EUR debt shows both of its accounts.
    let euro = try #require(model.selectedDetails.first { $0.debt.currency == .EUR })
    #expect(euro.records.contains { $0.accountText.hasPrefix(PreviewData.monobank.name) })
    #expect(euro.records.contains { $0.accountText.hasPrefix(PreviewData.revolutEUR.name) })

    // A record without an account says so and is not in the account summary.
    try Self.select("Maria Sample", in: model)
    #expect(model.selectedDetails.flatMap(\.records).contains { $0.accountText == "No account" })
    #expect(model.selectedAccountFlows.map(\.id) == [PreviewData.monobank.id])
  }

  @Test("R-DEBT-14: the record form offers every open account, grouped; a cross-currency record saves both amounts")
  func recordFormAccounts() async throws {
    let model = try await Self.loadedModel()
    model.newRecord(debtID: DebtSample.alex.id)
    let offered = model.accountSections.flatMap(\.accounts).map(\.id)
    let open = model.accounts.filter { !$0.isArchived }.map(\.id)
    #expect(Set(offered) == Set(open) && offered.count == open.count)
    #expect(model.accountSections.contains { $0.group != nil })
    // EUR debt from the PLN account.
    model.recordDraft?.amount = "10"
    model.recordDraft?.accountID = PreviewData.pkoPersonal.id
    #expect(model.recordNeedsAccountAmount)
    model.recordDraft?.accountAmount = "43"
    await model.saveRecordDraft()
    #expect(model.recordDraft == nil)
    try Self.select("Alex Example", in: model)
    let pko = try #require(model.selectedAccountFlows.first { $0.id == PreviewData.pkoPersonal.id })
    #expect(pko.outText == "−" + model.format.money(Money(minorUnits: 43_00, currency: .PLN)))
  }

  @Test("R-DEBT-15: a person's total is their open balances converted to the display currency at today's rate")
  func personTotal() async throws {
    let model = try await Self.loadedModel(.UAH)
    try Self.select("Alex Example", in: model)
    // Alex: +€310 (300 + 80 − 120 + 50) and −zł250, never netted per currency.
    let euro = try #require(Self.rates.convertAtLatest(Money(minorUnits: 310_00, currency: .EUR), to: .UAH))
    let zloty = try #require(Self.rates.convertAtLatest(Money(minorUnits: -250_00, currency: .PLN), to: .UAH))
    let total = try #require(model.selectedTotal)
    #expect(total.balance?.money == Money(minorUnits: euro.minorUnits + zloty.minorUnits, currency: .UAH))
    #expect(total.isApproximate && total.caption == "Total in UAH at today's rates")
    let alex = try #require(model.people.first { $0.name == "Alex Example" })
    #expect(alex.balances.map(\.money) == [Money(minorUnits: 310_00, currency: .EUR), Money(minorUnits: -250_00, currency: .PLN)])
    #expect(alex.convertedText?.hasPrefix("≈ ") == true)

    // Maria owes only hryvnias: nothing converted while UAH is shown.
    let maria = try #require(model.people.first { $0.name == "Maria Sample" })
    #expect(maria.convertedText == nil)
    try Self.select("Maria Sample", in: model)
    #expect(model.selectedTotal?.isApproximate == false)
    #expect(model.selectedTotal?.balance?.money.currency == .UAH)
  }

  @Test("R-DEBT-15: the header totals equal the dashboard widget's in every display currency")
  func headerMatchesWidget() async throws {
    let model = try await Self.loadedModel()
    for currency in Currency.displayOrder {
      model.displayCurrency = currency
      let widget = DashboardDebts.make(book: model.book, currency: currency, converter: Self.rates, format: DashboardFormat())
      #expect(model.summary.currency == currency)
      #expect(model.summary.owedToMe == widget.owedToMe)
      #expect(model.summary.iOwe == widget.iOwe)
      // A person's ≈ figure is the widget's figure.
      for person in widget.people {
        let row = model.people.first { $0.id == person.id }
        #expect(row?.convertedText == person.convertedText)
      }
    }
  }

  @Test("R-DEBT-15: switching the display currency changes the converted figures, never the per-currency balances")
  func switchChangesFigures() async throws {
    let model = try await Self.loadedModel(.UAH)
    try Self.select("Maria Sample", in: model)
    let balancesBefore = model.people.map(\.balances)
    let owedInUAH = model.summary.owedToMe
    let mariaInUAH = model.selectedTotal?.balance?.money

    model.displayCurrency = .EUR
    #expect(model.summary.owedToMe.currency == .EUR && model.summary.owedToMe != owedInUAH)
    #expect(model.selectedTotal?.balance?.money.currency == .EUR && model.selectedTotal?.balance?.money != mariaInUAH)
    #expect(model.selectedTotal?.isApproximate == true)
    #expect(model.people.first { $0.name == "Maria Sample" }?.convertedText?.hasPrefix("≈ ") == true)
    #expect(model.people.map(\.balances) == balancesBefore)
  }
}
