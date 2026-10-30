import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// C26: the account editor's "Debt" section (R-DEBT-17). Real SQLite repositories over an
/// in-memory database with synthetic data (`PreviewData` + `DebtSample`).
@MainActor
@Suite("Account editor · Debt link (C26, R-DEBT-17)")
struct AccountDebtLinkTests {
  let database: any DatabaseWriter
  let debts: SQLiteDebtRepository
  let model: AccountsModel

  init() async throws {
    let database = try DebtSample.database()
    let format = ManageFixture.format
    let store = ManagePreviewStore.sample()
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    let dependencies = ManageDependencies(
      accounts: SQLiteAccountRepository(database: database), categories: store.categoryRepository,
      txns: SQLiteTxnRepository(database: database), budget: store.budgetRepository, events: store.eventRepository,
      rules: store.ruleRepository, settings: store.settingsRepository, converter: { rates },
      today: { PreviewData.today }, format: format, debts: SQLiteDebtRepository(database: database))
    self.database = database
    self.debts = SQLiteDebtRepository(database: database)
    self.model = AccountsModel(dependencies: dependencies)
    await model.load()
  }

  func open(_ account: Account) -> AccountDraft {
    model.select(account.id)
    return model.draft!
  }

  func link(of account: Account) async throws -> DebtAccountLink? {
    try await debts.book().links.first { $0.accountID == account.id }
  }

  @Test("R-DEBT-17: the section is offered, an unlinked account shows None and is not dirty")
  func offeredAndNone() {
    #expect(model.offersDebts)
    let draft = open(PreviewData.pkoPersonal)
    #expect(draft.debt == .none)
    #expect(!model.canSave(draft))
    #expect(model.debtNotice(draft) == nil)
  }

  @Test("R-DEBT-17: the debt list is searchable by name")
  func search() {
    #expect(Set(model.debtOptions(matching: "").map(\.id)).isSuperset(of: DebtSample.debts.map(\.id)))
    #expect(model.debtOptions(matching: "ALEX").map(\.id) == [DebtSample.alex.id])
    #expect(model.debtOptions(matching: "zzz").isEmpty)
  }

  @Test("R-DEBT-17: link an existing bank account to a debt as external; its kind stays Bank account")
  func linkExternal() async throws {
    var draft = open(PreviewData.pkoPersonal)
    draft.debt = .existing(DebtSample.sam.id)
    #expect(model.canSave(draft))
    #expect(model.debtRole(draft) == .external)
    await model.save(draft)
    let stored = try #require(try await link(of: PreviewData.pkoPersonal))
    #expect(stored.debtID == DebtSample.sam.id && stored.role == .external)
    #expect(model.account(PreviewData.pkoPersonal.id)?.kind == .bank)
    #expect(model.linkedDebt(of: PreviewData.pkoPersonal.id)?.id == DebtSample.sam.id)
    #expect(model.sheet == nil)
  }

  @Test("R-DEBT-17: a Debt (person) account is linked as virtual")
  func linkVirtual() async throws {
    var draft = open(PreviewData.loanFromFriend)
    #expect(draft.kind == .debt)
    draft.debt = .existing(DebtSample.sam.id)
    #expect(model.debtRole(draft) == .virtual)
    await model.save(draft)
    #expect(try await link(of: PreviewData.loanFromFriend)?.role == .virtual)
  }

  @Test("R-DEBT-17: choosing None unlinks; the account and its transactions stay")
  func unlink() async throws {
    var draft = open(DebtSample.mariaBank)
    #expect(draft.debt == .existing(DebtSample.maria.id))
    #expect(model.debtNotice(draft) == "Currently in Maria Sample.")
    draft.debt = .none
    #expect(model.debtNotice(draft)?.contains("removes it from that debt") == true)
    await model.save(draft)
    #expect(try await link(of: DebtSample.mariaBank) == nil)
    #expect(model.account(DebtSample.mariaBank.id) != nil)
  }

  @Test("R-DEBT-17: an account in another debt is moved on Save, with the notice 'Currently in …'")
  func move() async throws {
    var draft = open(DebtSample.mariaBank)
    draft.debt = .existing(DebtSample.sam.id)
    let notice = try #require(model.debtNotice(draft))
    #expect(notice.contains("Currently in Maria Sample") && notice.contains("moves it to Sam Placeholder"))
    #expect(model.canSave(draft))
    await model.save(draft)
    #expect(try await link(of: DebtSample.mariaBank)?.debtID == DebtSample.sam.id)
    let book = try await debts.book()
    #expect(book.links.filter { $0.accountID == DebtSample.mariaBank.id }.count == 1)
  }

  @Test("R-DEBT-17: a failed move puts the old link back")
  func failedMoveRestores() async throws {
    var draft = open(DebtSample.mariaBank)
    draft.debt = .existing(UUID())  // a debt that does not exist
    #expect(model.validationMessage(draft) == "That debt no longer exists.")
    #expect(!model.canSave(draft))
    #expect(try await link(of: DebtSample.mariaBank)?.debtID == DebtSample.maria.id)
  }

  @Test("R-DEBT-17: New debt… creates the debt by name (not counted in net worth) and links the account")
  func newDebtFromTheSheet() async throws {
    var draft = open(PreviewData.pkoPersonal)
    draft.debt = .new(name: "  Taylor Test ")
    #expect(model.debtNotice(draft) == "A new debt is created for this person when you save.")
    await model.save(draft)
    let book = try await debts.book()
    let created = try #require(book.debts.first { $0.personName == "Taylor Test" })
    #expect(!created.countsInNetWorth)
    #expect(book.debtID(ofAccount: PreviewData.pkoPersonal.id) == created.id)
    #expect(model.debt(created.id) != nil)
  }

  @Test("R-DEBT-17: New debt… needs a name that is not an existing person")
  func newDebtValidation() {
    var draft = open(PreviewData.pkoPersonal)
    draft.debt = .new(name: "  ")
    #expect(model.validationMessage(draft) == "Enter a name for the new debt.")
    draft.debt = .new(name: "alex example")
    #expect(model.validationMessage(draft)?.contains("already exists") == true)
    #expect(!model.canSave(draft))
  }

  @Test("R-DEBT-17: a new account is created and linked in one Save (existing and new debt)")
  func newAccountWithDebt() async throws {
    model.newAccount(currency: .EUR)
    var draft = try #require(model.draft)
    draft.name = "Revolut Taylor"
    draft.debt = .existing(DebtSample.alex.id)
    await model.save(draft)
    let created = try #require(model.accounts.first { $0.name == "Revolut Taylor" })
    #expect(created.kind == .bank)
    #expect(try await link(of: created)?.debtID == DebtSample.alex.id)
    #expect(try await link(of: created)?.role == .external)

    model.newAccount(currency: .PLN)
    var second = try #require(model.draft)
    second.name = "Taylor PLN"
    second.kind = .debt
    second.debt = .new(name: "Taylor Test")
    await model.save(second)
    let other = try #require(model.accounts.first { $0.name == "Taylor PLN" })
    let book = try await debts.book()
    let debt = try #require(book.debt(person: "Taylor Test"))
    #expect(book.debtID(ofAccount: other.id) == debt.id)
    #expect(try await link(of: other)?.role == .virtual)
  }

  @Test("R-DEBT-17: changing the kind of a linked account updates its role")
  func kindChangeUpdatesRole() async throws {
    var draft = open(DebtSample.mariaBank)
    draft.kind = .debt
    #expect(model.debtRole(draft) == .virtual)
    await model.save(draft)
    #expect(try await link(of: DebtSample.mariaBank)?.role == .virtual)
  }

  @Test("R-DEBT-17: without a debt repository the section is not offered")
  func notOffered() async {
    let plain = AccountsModel(dependencies: ManageFixture.dependencies(.sample()))
    await plain.load()
    #expect(!plain.offersDebts)
  }

  @Test("R-ACC-1: the kind picker offers Debt (person) only to a debt account; the kind is not locked by transactions")
  func kindPickerAndLock() {
    #expect(!ManageText.liabilityKinds(offeredFor: .bank).contains(.debt))
    #expect(ManageText.liabilityKinds(offeredFor: .debt).contains(.debt))
    // The currency is the only field locked by transactions.
    let draft = open(PreviewData.pkoPersonal)
    #expect(model.isCurrencyLocked(draft))
  }
}
