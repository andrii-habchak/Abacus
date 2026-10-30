import AbacusDomain
import AbacusFX
import AbacusStore
import Foundation
import SQLiteData
import Testing

@testable import AbacusFeatures

/// C29: kind change (R-ACC-1/2, R-DEBT-17/18), kind filter (R-MGMT-9) and archive with a balance
/// (R-ACC-4, R-DEBT-4/17/18). Real SQLite repositories over an in-memory database with synthetic
/// data (`PreviewData` + `DebtSample`).
@MainActor
@Suite("Accounts · kind change, kind filter, archive with balance (C29)")
struct AccountKindArchiveTests {
  let database: any DatabaseWriter
  let debts: SQLiteDebtRepository
  let txns: SQLiteTxnRepository
  let categories: SQLiteCategoryRepository
  let model: AccountsModel
  let today = PreviewData.today

  init() async throws {
    let database = try DebtSample.database()
    let store = ManagePreviewStore.sample()
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    let txns = SQLiteTxnRepository(database: database)
    let categories = SQLiteCategoryRepository(database: database)
    let dependencies = ManageDependencies(
      accounts: SQLiteAccountRepository(database: database), categories: categories, txns: txns,
      budget: store.budgetRepository, events: store.eventRepository, rules: store.ruleRepository,
      settings: store.settingsRepository, converter: { rates }, today: { PreviewData.today },
      format: ManageFixture.format, debts: SQLiteDebtRepository(database: database))
    self.database = database
    self.debts = SQLiteDebtRepository(database: database)
    self.txns = txns
    self.categories = categories
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

  func balance(_ account: Account) -> Int64 { model.balance(model.account(account.id)!).minorUnits }

  // MARK: Kind change (R-ACC-1, R-ACC-2, R-DEBT-17, R-DEBT-18)

  @Test("R-ACC-1: the kind picker offers Debt (person) to every account when debts are available")
  func pickerOffersDebt() {
    let bank = open(PreviewData.pkoPersonal)
    #expect(model.liabilityKindOptions(for: bank) == [.creditCard, .loan, .debt])
    #expect(!ManageText.liabilityKinds(offeredFor: .bank).contains(.debt))
    #expect(ManageText.liabilityKinds(offeredFor: .debt).contains(.debt))
  }

  @Test("R-ACC-1, R-DEBT-17: a bank account with transactions cannot become Debt (person) without a debt")
  func debtKindNeedsDebt() {
    var draft = open(PreviewData.pkoPersonal)
    #expect(model.isCurrencyLocked(draft))  // it has transactions
    draft.kind = .debt
    #expect(model.validationMessage(draft) == "Choose or create the debt for a Debt (person) account.")
    #expect(!model.canSave(draft))
  }

  @Test("R-ACC-1, R-DEBT-17: a bank account with transactions becomes Debt (person) and is linked to a debt in one Save, role external")
  func bankToDebtExisting() async throws {
    var draft = open(PreviewData.pkoPersonal)
    let before = balance(PreviewData.pkoPersonal)
    draft.kind = .debt
    draft.debt = .existing(DebtSample.sam.id)
    #expect(model.canSave(draft))
    #expect(model.debtRole(draft) == .external)
    await model.save(draft)
    #expect(model.account(PreviewData.pkoPersonal.id)?.kind == .debt)
    let stored = try #require(try await link(of: PreviewData.pkoPersonal))
    #expect(stored.debtID == DebtSample.sam.id && stored.role == .external)
    #expect(balance(PreviewData.pkoPersonal) == before)  // the transactions are untouched
    #expect(model.sheet == nil)
  }

  @Test("R-ACC-1, R-DEBT-17: a bank account becomes Debt (person) with a new debt created in the same sheet")
  func bankToDebtNew() async throws {
    var draft = open(PreviewData.pkoPersonal)
    draft.kind = .debt
    draft.debt = .new(name: "Jordan Test")
    await model.save(draft)
    let book = try await debts.book()
    let debt = try #require(book.debt(person: "Jordan Test"))
    #expect(book.debtID(ofAccount: PreviewData.pkoPersonal.id) == debt.id)
    #expect(model.account(PreviewData.pkoPersonal.id)?.kind == .debt)
  }

  @Test("R-DEBT-17: the link role stays when the kind changes (external never flips to virtual)")
  func roleStaysExternal() async throws {
    var draft = open(DebtSample.mariaBank)
    #expect(try await link(of: DebtSample.mariaBank)?.role == .external)
    draft.kind = .debt
    #expect(model.validationMessage(draft) == nil)  // already in a debt
    #expect(model.debtRole(draft) == .external)
    #expect(model.debtRoleHint(draft)?.contains("role does not change") == true)
    await model.save(draft)
    #expect(try await link(of: DebtSample.mariaBank)?.role == .external)
    #expect(model.account(DebtSample.mariaBank.id)?.kind == .debt)
  }

  @Test("R-DEBT-17: a virtual account changed away from Debt (person) stays linked as virtual")
  func roleStaysVirtual() async throws {
    var draft = open(DebtSample.alexEUR)
    draft.kind = .card
    await model.save(draft)
    let stored = try #require(try await link(of: DebtSample.alexEUR))
    #expect(stored.role == .virtual && stored.debtID == DebtSample.alex.id)
    #expect(model.account(DebtSample.alexEUR.id)?.kind == .card)
  }

  @Test("R-DEBT-17: a Debt (person) account cannot be taken out of its debt")
  func debtKindCannotBeUnlinked() {
    var draft = open(DebtSample.alexEUR)
    draft.debt = .none
    #expect(model.validationMessage(draft) == "Choose or create the debt for a Debt (person) account.")
    draft.kind = .bank  // as a bank account it may leave the debt
    #expect(model.validationMessage(draft) == nil)
  }

  @Test("R-DEBT-17: a Debt (person) account can move to another debt")
  func debtKindMoves() async throws {
    var draft = open(DebtSample.alexEUR)
    draft.debt = .existing(DebtSample.sam.id)
    await model.save(draft)
    #expect(try await link(of: DebtSample.alexEUR)?.debtID == DebtSample.sam.id)
  }

  @Test("R-ACC-2: a debt account becomes a bank account (kind free in both directions)")
  func debtToBank() async throws {
    var draft = open(PreviewData.loanFromFriend)
    draft.kind = .bank
    draft.debt = .none
    await model.save(draft)
    #expect(model.account(PreviewData.loanFromFriend.id)?.kind == .bank)
    #expect(try await link(of: PreviewData.loanFromFriend) == nil)
  }

  @Test("R-ACC-2, R-DEBT-18: the sheet notes an asset/liability class change; linked accounts count through the debt")
  func classChangeNote() {
    var draft = open(PreviewData.pkoPersonal)
    #expect(model.kindChangeNote(draft) == nil)
    draft.kind = .card  // asset to asset
    #expect(model.kindChangeNote(draft) == nil)
    draft.kind = .creditCard
    #expect(model.kindChangeNote(draft) == "Net worth: the balance moves from Assets to Liabilities (the total does not change).")
    var liability = open(PreviewData.pkoCreditCard)
    liability.kind = .bank
    #expect(model.kindChangeNote(liability)?.contains("from Liabilities to Assets") == true)
    var linked = open(DebtSample.mariaBank)
    linked.kind = .loan
    #expect(model.kindChangeNote(linked)?.contains("only through the debt") == true)
    model.newAccount(currency: .EUR)
    var fresh = model.draft!
    fresh.kind = .loan
    #expect(model.kindChangeNote(fresh) == nil)
  }

  @Test("R-ACC-1: without a debt repository the debt kind is offered only to a debt account and is not forced to link")
  func withoutDebtRepository() async {
    let plain = AccountsModel(dependencies: ManageFixture.dependencies(.sample()))
    await plain.load()
    plain.select(PreviewData.pkoPersonal.id)
    var draft = plain.draft!
    #expect(plain.liabilityKindOptions(for: draft) == [.creditCard, .loan])
    draft.kind = .debt
    #expect(plain.validationMessage(draft) == nil)
  }

  // MARK: Kind filter (R-MGMT-9)

  @Test("R-MGMT-9: the kind filter is multi-select and narrows the list; groups with no match are hidden")
  func kindFilter() {
    let all = model.rows.filter { !$0.isGroup }.count
    model.toggleKind(.bank)
    let banks = model.rows.filter { !$0.isGroup }
    #expect(!banks.isEmpty && banks.count < all)
    #expect(banks.allSatisfy { $0.detail.hasPrefix("Bank account") })
    #expect(model.kindFilterLabel == "Bank account")
    model.toggleKind(.cash)
    #expect(model.kindFilterLabel == "Cash +1")
    #expect(model.rows.contains { $0.id == PreviewData.cashPLN.id })
    #expect(model.rows.contains { $0.id == PreviewData.pkoPersonal.id })
    #expect(!model.rows.contains { $0.id == PreviewData.eurDeposit.id })
    model.toggleKind(.bank)
    model.toggleKind(.cash)
    #expect(model.kindFilter.isEmpty && model.kindFilterLabel == "All types")
    #expect(model.rows.filter { !$0.isGroup }.count == all)
  }

  @Test("R-MGMT-9: the kind choices cascade from the currency filter; a selected kind stays removable")
  func kindOptionsCascade() {
    #expect(model.kindOptions.contains(.savings) && model.kindOptions.contains(.cash))
    model.currencyFilter = .EUR
    #expect(model.kindOptions.contains(.savings))
    #expect(!model.kindOptions.contains(.cash))  // Cash PLN is not a EUR account
    model.toggleKind(.cash)
    #expect(model.kindOptions.contains(.cash))  // selected: kept so it can be unticked
    #expect(model.rows.isEmpty)
    #expect(model.emptySearchMessage == "No accounts match the filters.")
  }

  @Test("R-MGMT-9: the kind filter combines with the currency filter and the search; Clear filters resets both filters")
  func clearFilters() {
    model.currencyFilter = .PLN
    model.toggleKind(.bank)
    #expect(model.hasActiveFilters)
    let rows = model.rows.filter { !$0.isGroup }
    #expect(rows.map(\.name) == ["PKO Personal"])
    model.searchText = "PKO"
    #expect(model.rows.filter { !$0.isGroup }.map(\.name) == ["PKO Personal"])
    model.clearFilters()
    #expect(!model.hasActiveFilters && model.currencyFilter == nil && model.kindFilter.isEmpty)
    #expect(model.searchText == "PKO")  // the search is not a filter
  }

  // MARK: Archive with a balance (R-ACC-4)

  @Test("R-ACC-4: an account with a balance opens the archive sheet (balance, nothing changes before Archive)")
  func archiveSheetOpens() async throws {
    model.select(PreviewData.pkoPersonal.id)
    let shown = balance(PreviewData.pkoPersonal)
    #expect(shown != 0)
    await model.archiveOrUnarchive()
    let sheet = try #require(model.archiveSheet)
    #expect(model.dialog == nil)
    #expect(sheet.balance.minorUnits == shown && sheet.balanceText == model.balanceText)
    #expect(!sheet.isLinkedToDebt && !sheet.createCompensation)
    model.cancelArchiveSheet()
    #expect(model.archiveSheet == nil && model.account(PreviewData.pkoPersonal.id)?.isArchived == false)
  }

  @Test("R-ACC-4: Archive with the box unchecked archives as is; the balance and the transactions stay")
  func archiveAsIs() async throws {
    let before = try await txns.transactions(matching: TxnQuery()).count
    let balanceBefore = balance(PreviewData.pkoPersonal)
    model.select(PreviewData.pkoPersonal.id)
    await model.archiveOrUnarchive()
    await model.confirmArchive()
    #expect(model.account(PreviewData.pkoPersonal.id)?.isArchived == true)
    #expect(try await txns.transactions(matching: TxnQuery()).count == before)
    #expect(balance(PreviewData.pkoPersonal) == balanceBefore)
    #expect(model.archiveSheet == nil)
  }

  @Test("R-ACC-4: a zero balance keeps the one-line confirmation")
  func zeroBalanceDialog() async {
    model.select(PreviewData.cashPLN.id)
    // Cash PLN has no opening balance but ATM withdrawals; use a fresh empty account instead.
    model.newAccount(currency: .EUR)
    model.draft?.name = "Spare card"
    model.draft?.kind = .card
    await model.save()
    await model.archiveOrUnarchive()
    #expect(model.archiveSheet == nil)
    #expect(model.dialog?.confirmTitle == "Archive")
  }

  @Test("R-ACC-4: a positive balance with the box checked books an expense of |balance| today and zeroes the account")
  func compensationExpense() async throws {
    let account = PreviewData.pkoPersonal
    let amount = balance(account)
    #expect(amount > 0)
    model.select(account.id)
    await model.archiveOrUnarchive()
    model.setCreateCompensation(true)
    await model.confirmArchive()
    #expect(model.account(account.id)?.isArchived == true)
    #expect(balance(account) == 0)
    let created = try await txns.transactions(matching: TxnQuery(accountIDs: [account.id])).filter(\.txn.isBalanceCorrection)
    let correction = try #require(created.first)
    #expect(created.count == 1 && correction.lines.isEmpty)
    #expect(correction.txn.type == .expense && !correction.txn.isRefund)
    #expect(correction.txn.amountMinor == amount)
    #expect(correction.txn.note == AccountsModel.correctionNote)
    #expect(Day(correction.txn.occurredAt, calendar: ManageFixture.format.calendar) == today)
    let category = try #require(
      try await categories.categories(kind: .expense, includeArchived: true).first { $0.id == correction.txn.categoryID })
    #expect(category.name == "Balance correction" && category.kind == .expense)
  }

  @Test("R-ACC-4: a negative balance books an income; an existing Balance correction category is reused, never duplicated")
  func compensationIncomeReusesCategory() async throws {
    let account = PreviewData.pkoCreditCard
    let amount = balance(account)
    #expect(amount < 0)
    // A category of the owner's already named like that (kind income).
    let existing = AbacusDomain.Category(name: "Balance correction", kind: .income, position: 99)
    try await categories.save(existing)
    model.select(account.id)
    await model.archiveOrUnarchive()
    model.setCreateCompensation(true)
    await model.confirmArchive()
    #expect(balance(account) == 0)
    let correction = try #require(
      try await txns.transactions(matching: TxnQuery(accountIDs: [account.id])).first { $0.txn.isBalanceCorrection })
    #expect(correction.txn.type == .income && correction.txn.amountMinor == -amount)
    #expect(correction.txn.categoryID == existing.id)
    let named = try await categories.categories(kind: .income, includeArchived: true).filter { $0.name == "Balance correction" }
    #expect(named.count == 1)
  }

  @Test("R-ACC-4: the compensation stays on the account and out of every report")
  func compensationOutOfReports() async throws {
    let account = PreviewData.pkoPersonal
    let accounts = PreviewData.accounts
    let tree = PreviewData.categories
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    func totals(_ rows: [TxnWithLines]) -> (CategoryBreakdown, CategoryBreakdown, ListTotals) {
      (
        Calc.categoryTotals(
          kind: .expense, days: nil, accounts: accounts, categories: tree, txns: rows, currency: .PLN, converter: rates,
          refundsReduceSpending: false),
        Calc.categoryTotals(
          kind: .income, days: nil, accounts: accounts, categories: tree, txns: rows, currency: .PLN, converter: rates,
          refundsReduceSpending: false),
        Calc.listTotals(
          txns: rows, accounts: accounts, categories: tree, currency: .PLN, converter: rates,
          refundsReduceSpending: false)
      )
    }
    let before = try await txns.transactions(matching: TxnQuery())
    model.select(account.id)
    await model.archiveOrUnarchive()
    model.setCreateCompensation(true)
    await model.confirmArchive()
    let after = try await txns.transactions(matching: TxnQuery())
    #expect(after.count == before.count + 1)
    let (e1, i1, l1) = totals(before)
    let (e2, i2, l2) = totals(after)
    #expect(e1 == e2 && i1 == i2)
    #expect(l1.income == l2.income && l1.expense == l2.expense && l2.count == l1.count + 1)
    // The account list still shows it (it is an ordinary transaction of the account).
    #expect(after.contains { $0.txn.accountID == account.id && $0.txn.isBalanceCorrection })
  }

  @Test("R-ACC-4: Archive on the sheet closes the account editor sheet")
  func archiveClosesEditor() async {
    model.edit(PreviewData.pkoPersonal.id)
    #expect(model.sheet != nil)
    await model.archiveOrUnarchive()
    await model.confirmArchive()
    #expect(model.sheet == nil)
  }

  // MARK: Archive of an account in a debt (R-DEBT-4, R-DEBT-17, R-DEBT-18)

  @Test("R-DEBT-17: an account in a debt gets no compensation, the sheet offers 'Forgive the debt' instead")
  func debtSheetHasNoCompensation() async throws {
    model.select(DebtSample.alexEUR.id)
    await model.archiveOrUnarchive()
    let sheet = try #require(model.archiveSheet)
    #expect(sheet.isLinkedToDebt && sheet.debtName == "Alex Example")
    #expect(model.forgiveTitle(sheet).hasPrefix("Forgive the debt (") && model.forgiveTitle(sheet).hasSuffix("EUR)"))
    #expect(sheet.offersCountAsExpense && sheet.countAsExpense)  // they owe me: expense on by default
    // Even with the flag set by mistake, no transaction is booked for a debt account.
    model.setCreateCompensation(true)
    let before = try await txns.transactions(matching: TxnQuery()).count
    await model.confirmArchive()
    #expect(try await txns.transactions(matching: TxnQuery()).count == before)
    #expect(model.account(DebtSample.alexEUR.id)?.isArchived == true)
    #expect(try await debts.book().records.count == DebtSample.records.count)
  }

  @Test("R-DEBT-4, R-DEBT-18: forgiving an account owed to me adds a counted Forgave record; the debt reaches 0 in that currency; the account stays linked")
  func forgiveOwedToMe() async throws {
    let account = DebtSample.alexEUR
    let owed = balance(account)
    #expect(owed > 0)
    let calendar = ManageFixture.format.calendar
    var book = try await debts.book()
    #expect(Calc.debtBalance(book, debtID: DebtSample.alex.id, currency: .EUR, calendar: calendar).minorUnits == owed)
    model.select(account.id)
    await model.archiveOrUnarchive()
    model.setForgiveDebt(true)
    await model.confirmArchive()
    book = try await debts.book()
    let record = try #require(book.records.first { $0.debtID == DebtSample.alex.id })
    #expect(record.kind == .forgaveThem && record.amountMinor == owed && record.currency == .EUR)
    #expect(record.day == today.string)
    #expect(record.reportKind == .expense)
    #expect(record.categoryID != nil)  // the repository put it in "Debts"
    #expect(model.account(account.id)?.isArchived == true)
    #expect(book.debtID(ofAccount: account.id) == DebtSample.alex.id)  // still linked
    #expect(Calc.debtBalance(book, debtID: DebtSample.alex.id, currency: .EUR, calendar: calendar).minorUnits == 0)
    // The other currency of the same debt is untouched.
    #expect(Calc.debtBalance(book, debtID: DebtSample.alex.id, currency: .PLN, calendar: calendar).minorUnits == balance(DebtSample.alexPLN))
  }

  @Test("R-DEBT-4: 'Count as expense' can be turned off")
  func forgiveWithoutExpense() async throws {
    model.select(DebtSample.alexEUR.id)
    await model.archiveOrUnarchive()
    model.setForgiveDebt(true)
    model.setCountAsExpense(false)
    await model.confirmArchive()
    let record = try #require(try await debts.book().records.first { $0.debtID == DebtSample.alex.id })
    #expect(record.kind == .forgaveThem && record.reportKind == nil)
  }

  @Test("R-DEBT-18: an account I owe (negative) is forgiven by them: no expense flag is offered or stored")
  func forgiveIOwe() async throws {
    let account = DebtSample.alexPLN
    let owed = balance(account)
    #expect(owed < 0)
    model.select(account.id)
    await model.archiveOrUnarchive()
    let sheet = try #require(model.archiveSheet)
    #expect(!sheet.offersCountAsExpense)
    model.setForgiveDebt(true)
    await model.confirmArchive()
    let book = try await debts.book()
    let record = try #require(book.records.first { $0.debtID == DebtSample.alex.id })
    #expect(record.kind == .forgivenByThem && record.amountMinor == -owed && record.currency == .PLN)
    #expect(record.reportKind == nil)
    #expect(Calc.debtBalance(book, debtID: DebtSample.alex.id, currency: .PLN, calendar: ManageFixture.format.calendar).minorUnits == 0)
  }

  @Test("R-DEBT-17: unchecked, an account in a debt is archived without touching the debt")
  func debtArchiveUntouched() async throws {
    let before = try await debts.book()
    model.select(DebtSample.samPLN.id)
    await model.archiveOrUnarchive()
    await model.confirmArchive()
    let after = try await debts.book()
    #expect(model.account(DebtSample.samPLN.id)?.isArchived == true)
    #expect(after.records == before.records)
    #expect(after.links == before.links)
    #expect(
      Calc.debtBalances(after, calendar: ManageFixture.format.calendar)
        == Calc.debtBalances(before, calendar: ManageFixture.format.calendar))
  }
}
