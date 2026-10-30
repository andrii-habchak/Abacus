import AbacusDomain
import AbacusFX
import AbacusFeatures
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// WP C12 (TA v1.6, R-MGMT-8, R-MGMT-9, R-HOME-1, D48): account groups as folders, the Accounts
/// page's search, sort, currency filter and drag and drop, grouped A–Z pickers, and the net
/// worth breakdown by group.
@MainActor
@Suite("Accounts page (C12)")
struct AccountsPageTests {
  let store = ManagePreviewStore.sample()
  let mono = PreviewData.monobankGroup.id, pko = PreviewData.pkoGroup.id, revolut = PreviewData.revolutGroup.id
  let black = PreviewData.monobank.id, personal = PreviewData.pkoPersonal.id, usd = PreviewData.pkoUSD.id
  let credit = PreviewData.pkoCreditCard.id, eur = PreviewData.revolutEUR.id, cash = PreviewData.cashPLN.id
  let deposit = PreviewData.eurDeposit.id, loan = PreviewData.loanFromFriend.id

  func model() async -> AccountsModel {
    let model = AccountsModel(dependencies: ManageFixture.dependencies(store), displayCurrency: .UAH)
    await model.load()
    return model
  }

  func names(_ model: AccountsModel) -> [String] { model.rows.map(\.name) }

  // MARK: Groups

  @Test("R-MGMT-9: a group shows its account count and the sum of its accounts in the display currency")
  func groupSums() async throws {
    let model = await model()
    let rates = RateTable(rates: PreviewData.fxRates, today: PreviewData.today)
    let txns = try await store.txnRepository.transactions(matching: TxnQuery())
    let balances = Calc.balances(accounts: PreviewData.accounts, txns: txns, through: PreviewData.today)
    var expected = Money.zero(.UAH)
    for account in [PreviewData.pkoPersonal, PreviewData.pkoUSD, PreviewData.pkoCreditCard] {
      expected = expected + rates.convertAtLatest(balances[account.id]!, to: .UAH)!
    }
    let row = try #require(model.rows.first { $0.id == pko })
    #expect(row.isGroup)
    #expect(row.detail == "3 accounts")
    #expect(row.balanceText == ManageFixture.format.money(expected))
    #expect(model.groupSum(pko) == expected)
    #expect(model.rows.first { $0.id == mono }?.detail == "1 account")
    // Archived accounts are not counted (like net worth); the display currency follows the app.
    model.setDisplayCurrency(.PLN)
    let pln = try #require(model.groupSum(pko))
    #expect(pln.currency == .PLN)
    #expect(model.rows.first { $0.id == pko }?.balanceText == ManageFixture.format.money(pln))
  }

  @Test("R-MGMT-9: groups are created, renamed and deleted (accounts move to the top level)")
  func groupLifecycle() async throws {
    let model = await model()
    var changes = 0
    model.onDataChange = { changes += 1 }
    model.newGroup()
    #expect(model.inspectorTitle == "New group")
    #expect(model.draft == nil)
    #expect(model.validationMessage == "Enter a name.")
    #expect(!model.canSave)
    model.groupDraft?.name = "  Savings  "
    model.groupDraft?.colorHex = "#0F96B0"
    await model.save()
    let created = try #require(model.groups.first { $0.name == "Savings" })
    #expect(created.colorHex == "#0F96B0")
    #expect(model.selection == created.id)
    #expect(changes == 1)
    // A new group is last at the top level and shows while empty.
    #expect(names(model).last == "Savings")

    model.select(pko)
    #expect(model.groupDraft?.name == "PKO")
    #expect(model.selectedGroupSummary == "3 accounts")
    model.groupDraft?.name = "PKO BP"
    #expect(model.isDirty)
    await model.save()
    #expect(model.group(pko)?.name == "PKO BP")

    model.requestDeleteGroup()
    let dialog = try #require(model.dialog)
    #expect(dialog.title == "Delete group “PKO BP”?")
    #expect(dialog.message.hasPrefix("Its 3 accounts move to the top level"))
    await model.confirmDialog()
    #expect(model.group(pko) == nil)
    for id in [personal, usd, credit] {
      #expect(model.account(id)?.groupID == nil)
      #expect(model.rows.first { $0.id == id }?.isChild == false)
    }
    // Nothing else changed: same accounts, same balances.
    #expect(model.accounts.count == PreviewData.accounts.count)
  }

  @Test("R-MGMT-9: an account's Group picker moves it (last in the new group); New account starts in the selected group")
  func accountGroupField() async throws {
    let model = await model()
    #expect(model.groupOptions.map(\.name) == ["Monobank", "PKO", "Revolut"])
    model.select(cash)
    model.draft?.groupID = mono
    await model.save()
    #expect(model.account(cash)?.groupID == mono)
    #expect(names(model).prefix(3) == ["Monobank", "Monobank Black", "Cash PLN"])

    model.select(revolut)
    model.newAccount(currency: .EUR)
    #expect(model.draft?.groupID == revolut)
    model.select(personal)
    model.newAccount(currency: .PLN)
    #expect(model.draft?.groupID == pko)
  }

  // MARK: Sort, search, currency filter

  @Test("R-MGMT-9: sort Name A–Z / Z–A / Custom order; remembered")
  func sorting() async throws {
    let model = await model()
    #expect(model.sort == .custom)
    await model.setSort(.nameAscending)
    #expect(
      names(model) == [
        "Cash PLN", "EUR Deposit", "Loan from friend", "Monobank", "Monobank Black", "PKO", "PKO Credit Card",
        "PKO Personal", "PKO USD", "Revolut", "Revolut EUR",
      ])
    await model.setSort(.nameDescending)
    #expect(names(model).prefix(5) == ["Revolut", "Revolut EUR", "PKO", "PKO USD", "PKO Personal"])
    #expect(try await store.settingsRepository.value(.accountSort) == "nameDescending")
    let again = await self.model()
    #expect(again.sort == .nameDescending)
  }

  @Test("R-MGMT-11: search matches account and group names; a match brings its group")
  func search() async {
    let model = await model()
    model.searchText = "usd"
    #expect(names(model) == ["PKO", "PKO USD"])
    #expect(model.rows.first?.matchesSearch == false)
    model.searchText = "pko"
    #expect(names(model) == ["PKO", "PKO Personal", "PKO USD", "PKO Credit Card"])
    #expect(model.rows.first?.matchesSearch == true)
    model.searchText = "deposit"
    #expect(names(model) == ["EUR Deposit"])
    model.searchText = "nothing"
    #expect(model.rows.isEmpty)
    #expect(model.emptySearchMessage == "No accounts match “nothing”.")
  }

  @Test("R-MGMT-9: the currency filter keeps one currency's accounts and their groups")
  func currencyFilter() async {
    let model = await model()
    #expect(model.currencyOptions == Currency.displayOrder)
    model.currencyFilter = .EUR
    #expect(names(model) == ["Revolut", "Revolut EUR", "EUR Deposit"])
    model.currencyFilter = .PLN
    #expect(names(model) == ["PKO", "PKO Personal", "PKO Credit Card", "Cash PLN"])
    model.searchText = "cash"
    #expect(names(model) == ["Cash PLN"])
    model.currencyFilter = nil
    model.searchText = ""
    #expect(names(model).count == 11)
  }

  // MARK: Drag and drop

  @Test("R-MGMT-9: onto a group moves an account in (last); the sort stays")
  func dropOntoGroup() async throws {
    let model = await model()
    await model.setSort(.nameAscending)
    #expect(model.canDrop(cash, on: pko, position: .onto))
    await model.drop(cash, on: pko, position: .onto)
    #expect(model.account(cash)?.groupID == pko)
    #expect(model.sort == .nameAscending)
    // Onto a top-level account: a new group of both, after a name prompt (D55, OutlineListsTests).
    #expect(model.canDrop(loan, on: deposit, position: .onto))
    // Onto an account in a group: into that group.
    await model.drop(deposit, on: eur, position: .onto)
    #expect(model.account(deposit)?.groupID == revolut)
    // Not a group into a group, not into its own group.
    #expect(!model.canDrop(mono, on: pko, position: .onto))
    #expect(!model.canDrop(personal, on: pko, position: .onto))
    // Balances are untouched.
    let store = try await self.store.accountRepository.accounts(includeArchived: true)
    #expect(store.first { $0.id == cash }?.openingBalanceMinor == PreviewData.cashPLN.openingBalanceMinor)
  }

  @Test("R-MGMT-9: between rows reorders and switches to Custom order; between top-level rows leaves the group")
  func dropBetween() async throws {
    let model = await model()
    await model.setSort(.nameAscending)
    // Out of PKO, above Cash PLN (top level).
    await model.drop(usd, on: cash, position: .before)
    #expect(model.sort == .custom)
    #expect(model.account(usd)?.groupID == nil)
    #expect(
      names(model) == [
        "PKO USD", "Cash PLN", "EUR Deposit", "Loan from friend", "Monobank", "Monobank Black", "PKO",
        "PKO Credit Card", "PKO Personal", "Revolut", "Revolut EUR",
      ])
    // Next to an account in a group: into that group there.
    await model.drop(loan, on: personal, position: .before)
    #expect(model.account(loan)?.groupID == pko)
    let pkoBlock = names(model).drop { $0 != "PKO" }.prefix(4)
    #expect(Array(pkoBlock) == ["PKO", "PKO Credit Card", "Loan from friend", "PKO Personal"])
    // Right below a group whose accounts follow: its first account.
    await model.drop(cash, on: mono, position: .after)
    #expect(model.account(cash)?.groupID == mono)
    #expect(names(model).drop { $0 != "Monobank" }.prefix(3) == ["Monobank", "Cash PLN", "Monobank Black"])
    // A group moves with its accounts; it never goes into a group.
    await model.drop(revolut, on: PreviewData.pkoUSD.id, position: .before)
    #expect(names(model).prefix(2) == ["Revolut", "Revolut EUR"])
    #expect(!model.canDrop(revolut, on: personal, position: .before))
    // The space below the list: top level, last.
    await model.drop(black, on: nil, position: .after)
    #expect(model.account(black)?.groupID == nil)
    #expect(names(model).last == "Monobank Black")
    // Custom order survives a reload.
    let again = await self.model()
    #expect(names(again) == names(model))
  }

  @Test("R-MGMT-9: hidden archived accounts keep their place; drops work with a search or filter on")
  func dropWithHiddenRows() async throws {
    let model = await model()
    model.currencyFilter = .EUR
    await model.drop(deposit, on: revolut, position: .onto)
    #expect(model.account(deposit)?.groupID == revolut)
    model.currencyFilter = nil
    model.setShowArchived(true)
    #expect(names(model).last == "Old card")
  }

  // MARK: Pickers (R-MGMT-8)

  @Test("R-MGMT-8: pickers list groups A–Z with their accounts A–Z, ungrouped accounts after")
  func pickerOrder() {
    let sections = AccountOrder.pickerSections(PreviewData.accounts.filter { !$0.isArchived }, groups: PreviewData.accountGroups)
    #expect(sections.map(\.title) == ["Monobank", "PKO", "Revolut", nil])
    #expect(sections[1].accounts.map(\.name) == ["PKO Credit Card", "PKO Personal", "PKO USD"])
    #expect(sections[3].accounts.map(\.name) == ["Cash PLN", "EUR Deposit", "Loan from friend"])
    // Without groups: one plain A–Z list.
    let plain = AccountOrder.pickerSections(PreviewData.accounts, groups: [])
    #expect(plain.count == 1)
    #expect(plain[0].title == nil)
    #expect(plain[0].accounts.first?.name == "Cash PLN")
    #expect(AccountOrder.label(PreviewData.pkoUSD, groups: PreviewData.accountGroups) == "PKO › PKO USD")
    #expect(AccountOrder.label(PreviewData.cashPLN, groups: PreviewData.accountGroups) == "Cash PLN")
    // Natural order: "Card 2" before "Card 10".
    let cards = [10, 2].map { Account(name: "Card \($0)", currency: .PLN, kind: .card, openingDate: Date()) }
    #expect(AccountOrder.alphabetical(cards, groups: []).map(\.name) == ["Card 2", "Card 10"])
  }

  @Test("R-MGMT-8: the editor, transactions filter and rules use the grouped A–Z order")
  func pickersEverywhere() async throws {
    let expected = AccountOrder.alphabetical(
      PreviewData.accounts.filter { !$0.isArchived }, groups: PreviewData.accountGroups
    ).map(\.name)
    let editor = await EditorHarness.loaded()
    #expect(editor.model.accountOptions.map(\.name) == expected)
    #expect(editor.model.accountSections.map(\.title) == ["Monobank", "PKO", "Revolut", nil])

    let transactions = TransactionsViewModel.preview()
    await transactions.load()
    // C28: only accounts with rows under the other filters (last 30 days) are offered, in the same order.
    let offered = Set(transactions.accountOptions.map(\.name))
    #expect(transactions.accountOptions.map(\.name) == expected.filter(offered.contains))
    #expect(transactions.accountSections.first?.title == "Monobank")

    let rules = RulesModel(dependencies: ManageFixture.dependencies(store))
    await rules.load()
    #expect(rules.accountOptions.map(\.name) == expected)
    #expect(rules.accountSections.last?.title == nil)
  }

  @Test("R-MGMT-8: import target account and transfer pickers are grouped A–Z")
  func importPickers() async throws {
    let h = ImportHarness(database: try PreviewData.database())
    await h.model.load()
    #expect(h.model.accountGroups.map(\.name) == ["Monobank", "PKO", "Revolut"])
    await h.model.open(data: ImportSamples.pko, fileName: ImportSamples.pkoFileName)
    #expect(h.model.targetOptions.map(\.name) == ["PKO Credit Card", "PKO Personal", "Cash PLN"])
    #expect(h.model.targetSections.map(\.title) == ["PKO", nil])
  }

  // MARK: Net worth (R-HOME-1)

  @Test("R-HOME-1: the net worth breakdown shows groups with their sums and accounts beneath")
  func netWorthBreakdown() async throws {
    let format = DashboardFormat(locale: Locale(identifier: "en_US"), calendar: .current)
    let model = DashboardModel(dependencies: .preview(format: format), displayCurrency: .UAH)
    await model.load()
    let netWorth = try #require(model.netWorth)
    let lines = netWorth.breakdown
    #expect(
      lines.map(\.name) == [
        "Monobank", "Monobank Black", "PKO", "PKO Personal", "PKO USD", "PKO Credit Card", "Revolut", "Revolut EUR",
        "Cash PLN", "EUR Deposit", "Loan from friend",
      ])
    #expect(lines.filter { $0.level == .group }.map(\.name) == ["Monobank", "PKO", "Revolut"])
    #expect(lines.filter { $0.level == .groupedAccount }.count == 5)
    #expect(lines.filter { $0.level == .account }.map(\.name) == ["Cash PLN", "EUR Deposit", "Loan from friend"])
    // A group's sum = the sum of its accounts' converted balances; totals unchanged.
    let pkoRows = netWorth.accounts.filter { [personal, usd, credit].contains($0.id) }
    let sum = pkoRows.compactMap(\.converted).reduce(Money.zero(.UAH), +)
    #expect(lines.first { $0.name == "PKO" }?.convertedText == format.money(sum))
    #expect(lines.first { $0.name == "PKO" }?.balanceText == "")
    #expect(lines.first { $0.name == "PKO" }?.detail == "3 accounts")
    #expect(netWorth.accounts.count == 8)
    #expect(!lines.contains { $0.name == "Old card" })
  }
}
