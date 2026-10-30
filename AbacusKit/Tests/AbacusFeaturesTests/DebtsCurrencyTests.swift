import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// C18 on the C19 core: a person's linked accounts (R-DEBT-17, R-DEBT-18) and the display-currency
/// switch on the Debts tab (R-DEBT-15). Synthetic data only (`DebtSample`, `PreviewData`).
@MainActor
@Suite("Debts: linked accounts and the currency switch (C18, C19)")
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

  @Test("R-DEBT-18: Calc.debtAccountFlows — money out and in per linked account, in its currency; other debts' accounts left out")
  func accountFlowsCalc() {
    let pat = Debt(personName: "Pat Test")
    let other = Debt(personName: "Other")
    let day = Date(timeIntervalSince1970: 1_790_000_000)
    let virtual = Account(name: "Pat EUR", currency: .EUR, kind: .debt, openingDate: day)
    let external = Account(name: "Pat bank", currency: .PLN, kind: .bank, openingDate: day)
    let foreign = Account(name: "Other EUR", currency: .EUR, kind: .debt, openingDate: day)
    let mine = UUID()
    func transfer(from: UUID, to: UUID, _ amount: Int64, received: Int64? = nil) -> TxnWithLines {
      TxnWithLines(
        txn: Txn(type: .transfer, occurredAt: day, accountID: from, amountMinor: amount, toAccountID: to, toAmountMinor: received),
        lines: [])
    }
    let book = DebtBook(
      debts: [pat, other],
      links: [
        DebtAccountLink(accountID: virtual.id, debtID: pat.id, role: .virtual),
        DebtAccountLink(accountID: external.id, debtID: pat.id, role: .external),
        DebtAccountLink(accountID: foreign.id, debtID: other.id, role: .virtual),
      ],
      accounts: [virtual, external, foreign],
      txns: [
        transfer(from: mine, to: virtual.id, 100_00),
        transfer(from: mine, to: virtual.id, 900_00, received: 20_00),  // paid from a UAH account
        transfer(from: virtual.id, to: mine, 30_00),
        transfer(from: mine, to: external.id, 480_00),
        transfer(from: mine, to: foreign.id, 999_00),
      ])
    let flows = Calc.debtAccountFlows(book, debtIDs: [pat.id])
    #expect(flows.map(\.accountID) == [virtual.id, external.id])
    #expect(flows[0].inMinor == 120_00 && flows[0].outMinor == 30_00 && flows[0].transactions == 3 && flows[0].role == .virtual)
    #expect(flows[1].inMinor == 480_00 && flows[1].outMinor == 0 && flows[1].transactions == 1 && flows[1].role == .external)
  }

  @Test("R-DEBT-17, R-DEBT-18: the person's detail lists every linked account with money out/in in the account's currency")
  func perAccountSummary() async throws {
    let model = try await Self.loadedModel()
    try Self.select("Alex Example", in: model)
    let flows = model.selectedAccountFlows
    // Two virtual accounts: EUR (paid from Revolut and Monobank) and PLN.
    #expect(Set(flows.map(\.id)) == [DebtSample.alexEUR.id, DebtSample.alexPLN.id])
    #expect(flows.map(\.name) == flows.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    let format = model.format
    let eur = try #require(flows.first { $0.id == DebtSample.alexEUR.id })
    #expect(eur.currency == .EUR)
    #expect(eur.inText == "+" + format.money(Money(minorUnits: 430_00, currency: .EUR)))  // 300 + 80 + 50
    #expect(eur.outText == "−" + format.money(Money(minorUnits: 120_00, currency: .EUR)))
    #expect(eur.recordsText == "4 transactions · virtual")
    let pln = try #require(flows.first { $0.id == DebtSample.alexPLN.id })
    #expect(pln.inText == nil && pln.outText == "−" + format.money(Money(minorUnits: 250_00, currency: .PLN)))

    // Maria: a virtual account with payments and an external account without any yet.
    try Self.select("Maria Sample", in: model)
    let maria = model.selectedAccountFlows
    #expect(Set(maria.map(\.id)) == [DebtSample.mariaUAH.id, DebtSample.mariaBank.id])
    let bank = try #require(maria.first { $0.id == DebtSample.mariaBank.id })
    #expect(bank.recordsText == "0 transactions · external" && bank.inText == nil && bank.outText == nil)
    // Manual records name no account.
    #expect(model.selectedDetails.flatMap(\.records).contains { $0.accountText == "Manual record" && $0.kindTitle.hasPrefix("Forgave") })
  }

  @Test("R-DEBT-18: one detail per currency of the debt; a manual record keeps its own currency")
  func detailsPerCurrency() async throws {
    let model = try await Self.loadedModel()
    try Self.select("Alex Example", in: model)
    #expect(model.selectedDetails.map(\.currency) == [.EUR, .PLN])
    model.newRecord(debtID: DebtSample.alex.id, kind: .forgaveThem, currency: .USD)
    #expect(model.recordDraft?.currency == .USD)
    model.recordDraft?.amount = "10"
    await model.saveRecordDraft()
    #expect(model.recordDraft == nil)
    let record = try #require(model.book.records(of: DebtSample.alex.id).first)
    #expect(record.currency == .USD && record.amountMinor == 10_00)
    #expect(model.selectedDetails.map(\.currency) == [.EUR, .USD, .PLN])
    #expect(model.selectedDetails.first { $0.currency == .USD }?.balance.money == Money(minorUnits: -10_00, currency: .USD))
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
    #expect(total.isApproximate && total.caption == "≈ total in UAH")
    let alex = try #require(model.people.first { $0.name == "Alex Example" })
    #expect(alex.balances.map(\.money) == [Money(minorUnits: 310_00, currency: .EUR), Money(minorUnits: -250_00, currency: .PLN)])
    #expect(alex.isApproximate && alex.total?.money.currency == .UAH)

    // Maria owes only hryvnias: nothing converted while UAH is shown.
    let maria = try #require(model.people.first { $0.name == "Maria Sample" })
    #expect(!maria.isApproximate && maria.secondaryText == nil)
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
        #expect(row?.total?.money == person.total)
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
    #expect(model.people.first { $0.name == "Maria Sample" }?.isApproximate == true)
    #expect(model.people.map(\.balances) == balancesBefore)
  }
}
