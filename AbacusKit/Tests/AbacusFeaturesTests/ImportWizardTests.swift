import AbacusDomain
import AbacusFeatures
import AbacusImport
import AbacusStore
import Foundation
import SQLiteData
import Testing

/// The import wizard's view model end to end: the real pipeline on an in-memory SQLite store,
/// fed with the synthetic fixtures of `AbacusImportTests` and the preview world's samples.
@MainActor
struct ImportHarness {
  nonisolated static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  nonisolated static let now = Date(timeIntervalSince1970: 1_790_000_000)

  let database: any DatabaseWriter
  let model: ImportWizardModel

  init(database: any DatabaseWriter, store: (any ImportStore)? = nil) {
    self.database = database
    var dependencies = ImportWizardDependencies.live(database: database, calendar: Self.calendar, now: { Self.now })
    if let store {
      let p = dependencies.pipeline
      dependencies.pipeline = ImportPipeline(
        store: store, accounts: p.accounts, categories: p.categories, events: p.events, rules: p.rules,
        calendar: Self.calendar, now: { Self.now }, refunds: p.refunds, counterparts: p.counterparts)
    }
    model = ImportWizardModel(dependencies: dependencies)
  }

  /// An empty database (plus `accounts`).
  static func empty(accounts: [Account] = [], store: ((any DatabaseWriter) -> any ImportStore)? = nil) async throws -> ImportHarness {
    let database = try AbacusDatabase.open(at: nil)
    let repository = SQLiteAccountRepository(database: database, calendar: calendar)
    for account in accounts { try await repository.save(account) }
    let harness = ImportHarness(database: database, store: store?(database))
    await harness.model.load()
    return harness
  }

  static func fixture(_ folder: String, _ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("AbacusImportTests/Fixtures/\(folder)/\(name).csv")
    return try Data(contentsOf: url)
  }

  func open(_ folder: String, _ name: String) async throws {
    await model.open(data: try Self.fixture(folder, name), fileName: "\(name).csv")
  }

  func txns() async throws -> [TxnWithLines] {
    try await SQLiteTxnRepository(database: database, calendar: Self.calendar).transactions(matching: TxnQuery())
  }

  func accounts() async throws -> [Account] {
    try await SQLiteAccountRepository(database: database, calendar: Self.calendar).accounts(includeArchived: true)
  }

  func events() async throws -> [Event] {
    try await SQLiteEventRepository(database: database).events(includeArchived: true)
  }

  func rules() async throws -> [CategoryRule] {
    try await SQLiteRuleRepository(database: database).rules()
  }

  func saveCategory(_ category: AbacusDomain.Category) async throws {
    try await SQLiteCategoryRepository(database: database).save(category)
    await model.load()
  }
}

private let pkoAccount = Account(
  id: PreviewData.id(9001), name: "PKO Personal", currency: .PLN, kind: .bank, openingBalanceMinor: 1_000_00,
  openingDate: Date(timeIntervalSince1970: 1_767_225_600), iban: "PL 99 9999 9999 9999 9999 9999 9999")
private let otherPLN = Account(
  id: PreviewData.id(9002), name: "Joint PLN", currency: .PLN, kind: .bank, openingDate: Date(timeIntervalSince1970: 1_767_225_600))
private let usdAccount = Account(
  id: PreviewData.id(9003), name: "Wallet USD", currency: .USD, kind: .cash, openingDate: Date(timeIntervalSince1970: 1_767_225_600))

/// An import store whose commit fails, as a disk or constraint error would.
struct FailingCommitStore: ImportStore {
  let base: SQLiteImportStore
  struct Failure: LocalizedError {
    var errorDescription: String? { "The disk is full." }
  }

  func existingFingerprints(_ ids: [String]) async throws -> [String: Txn.ID] { try await base.existingFingerprints(ids) }
  func candidates(accountID: Account.ID, amountMinor: Int64, from: Day, to: Day) async throws -> [Txn] {
    try await base.candidates(accountID: accountID, amountMinor: amountMinor, from: from, to: to)
  }
  func pendingTxns(accountID: Account.ID, from: Day, to: Day) async throws -> [Txn] {
    try await base.pendingTxns(accountID: accountID, from: from, to: to)
  }
  func mappings(source: ImportSource) async throws -> [ImportMapping] { try await base.mappings(source: source) }
  func commit(_ commit: ImportCommit) async throws { throw Failure() }
  func batches() async throws -> [ImportBatch] { try await base.batches() }
  func undo(_ batchID: ImportBatch.ID) async throws { try await base.undo(batchID) }
}

@MainActor
@Suite("Import wizard view model")
struct ImportWizardTests {
  // MARK: Step 1 — file and format (R-IMP-1)

  @Test("R-IMP-1: a Saldo export is detected and previewed with counts, file bar and tabs")
  func saldoDetected() async throws {
    let h = try await ImportHarness.empty()
    #expect(h.model.step == .chooseFile)
    try await h.open("saldo", "spec-example")
    let model = h.model
    #expect(model.step == .review)
    #expect(model.file?.source == .saldo)
    #expect(model.formatLabel == "Saldo export")
    #expect(model.fileMeta == "4 rows · 1 Mar 2025 – 4 Mar 2025")
    #expect(model.cards.map(\.label) == ["All rows", "New", "Needs review"])
    #expect(model.cards.map(\.count) == ["4", "4", "0"])
    #expect(model.tabs.map(\.label) == ["Transactions", "Accounts & categories", "Events from tags", "Category assignment (0)", "Needs review (0)"])
    #expect(model.rowItems.map(\.statusLabel) == ["Opening balance", "New", "New transfer", "New transfer"])
    #expect(model.commitLabel == "Import 3 transactions")
    #expect(model.canCommit)
    // Nothing is written before the commit.
    #expect(try await h.txns().isEmpty)
    #expect(try await h.accounts().isEmpty)
  }

  @Test("R-IMP-1: a file that is neither Saldo nor PKO is refused with a message; the wizard stays on step 1")
  func unknownFormat() async throws {
    let h = try await ImportHarness.empty()
    await h.model.open(data: Data("Date;Amount\n2026-01-01;5\n".utf8), fileName: "notes.csv")
    #expect(h.model.step == .chooseFile)
    #expect(h.model.preview == nil)
    #expect(h.model.errorMessage == "“notes.csv” isn't a Saldo export or a PKO BP statement (“Zestawienie operacji”).")
  }

  @Test("R-IMP-1: a file read from disk goes through the same detection; unreadable files report an error")
  func openURL() async throws {
    let h = try await ImportHarness.empty()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("saldo.csv")
    try ImportHarness.fixture("saldo", "spec-example").write(to: url)
    await h.model.open(url: url)
    #expect(h.model.step == .review)
    #expect(h.model.file?.name == "saldo.csv")

    h.model.cancel()
    await h.model.open(url: folder.appendingPathComponent("missing.csv"))
    #expect(h.model.step == .chooseFile)
    #expect(h.model.errorMessage == "“missing.csv” couldn't be read.")
  }

  // MARK: PKO target account (R-IMP-PKO-1)

  @Test("R-IMP-PKO-1: a statement asks for its account; offers the currency's accounts; remembered after import")
  func pkoTargetAccount() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount, otherPLN, usdAccount])
    try await h.open("pko", "settled-later")
    let model = h.model
    #expect(model.step == .review)
    #expect(model.needsTargetAccount)
    #expect(model.formatLabel == "PKO BP statement")
    #expect(Set(model.targetOptions.map(\.name)) == ["PKO Personal", "Joint PLN"])
    #expect(!model.canCommit)

    await model.chooseTargetAccount(pkoAccount.id)
    #expect(!model.needsTargetAccount)
    #expect(model.targetAccountID == pkoAccount.id)
    #expect(!model.targetRemembered)
    #expect(model.mappingGroups.first?.items.first?.note == ImportNote("Chosen above"))
    #expect(model.cards.map(\.label) == ["All rows", "New", "Already imported", "Possible duplicates", "Settle pending", "Needs review"])
    await model.commit()
    #expect(model.step == .done)

    // The next statement in PLN goes to the same account without asking.
    model.cancel()
    try await h.open("pko", "settled-later")
    #expect(!model.needsTargetAccount)
    #expect(model.targetAccountID == pkoAccount.id)
    #expect(model.targetRemembered)
    #expect(model.mappingGroups.first?.items.first?.note == ImportNote("Remembered from the last PKO import", .success))
    #expect(model.preview?.counts.alreadyImported == 2)
  }

  @Test("R-IMP-PKO-1: changing the target account rebuilds the preview for that account")
  func pkoChangeTarget() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount, otherPLN])
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(pkoAccount.id)
    await h.model.commit()
    h.model.cancel()
    try await h.open("pko", "settled-later")
    #expect(h.model.preview?.counts.alreadyImported == 2)

    await h.model.chooseTargetAccount(otherPLN.id)
    #expect(h.model.targetAccountID == otherPLN.id)
    #expect(h.model.preview?.counts.alreadyImported == 0)
    #expect(h.model.preview?.counts.new == 2)
    #expect(h.model.rowItems.allSatisfy { $0.account == "Joint PLN" })
  }

  // MARK: Review — cards, rows, categories, duplicates

  @Test("R-IMP-1: summary cards filter the rows; the Needs review card opens its tab")
  func cardsFilter() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount])
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(pkoAccount.id)
    let model = h.model
    let counts = try #require(model.preview?.counts)
    #expect(model.visibleRows.count == counts.all)
    model.selectFilter(.new)
    #expect(model.visibleRows.count == counts.new)
    #expect(model.visibleRows.allSatisfy { $0.status == .new })
    #expect(model.tab == .transactions)
    model.selectFilter(.needsReview)
    #expect(model.tab == .review)
    #expect(model.visibleRows.count == counts.needsReview)
    #expect(model.reviewItems.count == counts.needsReview)
    model.selectFilter(nil)
    #expect(model.visibleRows.count == counts.all)
  }

  @Test("R-IMP-8: a category picked for an uncategorised row becomes a rule; it can be turned off")
  func categoryPickSavesRule() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount])
    let groceries = AbacusDomain.Category(id: PreviewData.id(9100), name: "Groceries", kind: .expense)
    try await h.saveCategory(groceries)
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(pkoAccount.id)
    let model = h.model
    let row = try #require(model.rowItems.first { $0.payee.contains("GROCERY") && !$0.isInflow })
    guard case .picker(.none, let options, true) = row.category else {
      Issue.record("Expected an empty picker that needs a category, got \(row.category)")
      return
    }
    #expect(options.contains { $0.label == "Groceries" })
    #expect(row.note == ImportNote("Needs a category", .attention))
    let uncategorised = try #require(model.preview?.uncategorisedCount)

    model.setCategory(.existing(groceries.id), forRow: row.id)
    let picked = try #require(model.rowItems.first { $0.id == row.id })
    #expect(picked.note == ImportNote("Will be saved as a rule “grocery store”", .info))
    #expect(picked.savesRule == true)
    #expect(model.preview?.rulesToSave.map(\.pattern) == ["grocery store"])
    #expect(model.footerNote.contains("1 new rule will be saved from your choices."))
    #expect(try #require(model.preview?.uncategorisedCount) < uncategorised)

    model.setSavesRule(false, forRow: row.id)
    #expect(model.rowItems.first { $0.id == row.id }?.note == ImportNote("Not saved as a rule"))
    #expect(model.preview?.rulesToSave.isEmpty == true)
    model.setSavesRule(true, forRow: row.id)
    #expect(model.preview?.rulesToSave.count == 1)

    model.acceptSuggestions()
    await model.commit()
    #expect(model.step == .done)
    #expect(try await h.rules().map(\.pattern) == ["grocery store"])
    #expect(model.doneLines.contains("1 new categorisation rule saved"))
  }

  @Test("R-IMP-8: rows categorised by an existing rule say so")
  func rowsByRule() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount])
    let taxi = AbacusDomain.Category(id: PreviewData.id(9101), name: "Taxi", kind: .expense)
    try await h.saveCategory(taxi)
    try await SQLiteRuleRepository(database: h.database).save(
      CategoryRule(id: PreviewData.id(9102), pattern: "taxi app", categoryID: taxi.id, origin: .manual))
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(pkoAccount.id)
    let row = try #require(h.model.rowItems.first { $0.payee.contains("TAXI APP") })
    #expect(row.note == ImportNote("By rule “taxi app”"))
    guard case .picker(.existing(taxi.id), _, false) = row.category else {
      Issue.record("Expected Taxi selected, got \(row.category)")
      return
    }
  }

  @Test("R-IMP-4: a possible duplicate is skipped by default; Import anyway and Link change what is written")
  func possibleDuplicates() async throws {
    let dependencies = try await ImportWizardDependencies.preview()
    let model = ImportWizardModel(dependencies: dependencies)
    await model.load()
    await model.open(data: ImportSamples.pko, fileName: ImportSamples.pkoFileName)
    #expect(model.preview?.counts.possibleDuplicate == 1)
    let rent = try #require(model.rowItems.first { $0.status == .possibleDuplicate })
    #expect(rent.duplicateAction == .skip)
    #expect(rent.isDimmed)
    #expect(rent.category == .none)
    #expect(rent.detail.hasPrefix("Looks like “Rent October” of 2026-10-12, same amount"))
    let base = try #require(model.preview?.transactionsToCreate)

    model.setDuplicateAction(.importAnyway, forRow: rent.id)
    let anyway = try #require(model.rowItems.first { $0.id == rent.id })
    #expect(!anyway.isDimmed)
    guard case .picker = anyway.category else {
      Issue.record("Import anyway shows the category picker")
      return
    }
    #expect(model.preview?.transactionsToCreate == base + 1)

    model.setDuplicateAction(.link, forRow: rent.id)
    #expect(model.preview?.transactionsToCreate == base)
    model.acceptSuggestions()
    await model.commit()
    #expect(model.step == .done)
    #expect(model.summary?.created == base + 1)  // + the reviewed card fee
    #expect(model.summary?.linked == 1)
    #expect(model.doneLines.contains { $0.contains("linked to existing") })
  }

  // MARK: Mappings (R-IMP-2)

  @Test("R-IMP-2: source accounts and categories map to existing ones or are created; changes are kept")
  func mappings() async throws {
    let h = try await ImportHarness.empty(accounts: [usdAccount])
    let eating = AbacusDomain.Category(id: PreviewData.id(9110), name: "Restaurants", kind: .expense)
    try await h.saveCategory(eating)
    try await h.open("saldo", "spec-example")
    let model = h.model
    let groups = model.mappingGroups
    #expect(groups.map(\.title) == ["Accounts", "Categories"])
    let wallet = try #require(groups[0].items.first { $0.source == "Wallet USD" })
    #expect(wallet.selection == .existing(usdAccount.id))
    #expect(wallet.note == ImportNote("Same name"))
    let bankUSD = try #require(groups[0].items.first { $0.source == "Bank USD" })
    #expect(bankUSD.selection == .create)
    #expect(bankUSD.options.map(\.label) == ["Create “Bank USD” (Bank)", "Wallet USD · USD"])

    await model.mapAccount(key: bankUSD.id, to: .existing(usdAccount.id))
    let mapped = try #require(model.mappingGroups[0].items.first { $0.id == bankUSD.id })
    #expect(mapped.selection == .existing(usdAccount.id))
    #expect(mapped.note == ImportNote("Mapped by you"))

    let category = try #require(model.mappingGroups[1].items.first { $0.source == "Eating out" })
    #expect(category.selection == .create)
    model.mapCategory(key: category.id, to: .existing(eating.id))
    #expect(model.mappingGroups[1].items.first { $0.id == category.id }?.selection == .existing(eating.id))

    await model.commit()
    #expect(model.step == .done)
    let names = try await h.accounts().map(\.name).sorted()
    #expect(names == ["Bank EUR", "Bank UAH", "Wallet USD"])
    let cafe = try #require(try await h.txns().first { $0.txn.payee == "CAFE" })
    #expect(cafe.txn.categoryID == eating.id)
  }

  @Test("R-IMP-2: a source account can't be mapped to an account in another currency")
  func mappingCurrencyMismatch() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount])
    try await h.open("saldo", "spec-example")
    let key = try #require(h.model.mappingGroups[0].items.first { $0.source == "Bank USD" }?.id)
    await h.model.mapAccount(key: key, to: .existing(pkoAccount.id))
    #expect(h.model.errorMessage == "Only an account in the same currency can be used.")
    #expect(h.model.mappingGroups[0].items.first { $0.id == key }?.selection == .create)
  }

  @Test("R-IMP-PKO-3: PKO counterparties: ATM withdrawals to the cash account, own accounts by number")
  func pkoCounterparties() async throws {
    let h = ImportHarness(database: try PreviewData.database())
    await h.model.load()
    await h.model.open(data: ImportSamples.pko, fileName: ImportSamples.pkoFileName)
    await h.model.chooseTargetAccount(PreviewData.pkoPersonal.id)
    let groups = h.model.mappingGroups
    #expect(groups.map(\.title) == ["Account", "Counterparties"])
    #expect(groups[0].items.first?.selectionLabel == "PKO Personal · PLN")
    let items = groups[1].items
    #expect(items.first { $0.source == "Cash" }?.selection == .existing(PreviewData.cashPLN.id))
    let own = try #require(items.first { $0.kind == .fixed })
    #expect(own.selectionLabel == "PKO USD · USD (own account)")
    #expect(own.note == ImportNote("Matched by account number → transfer"))
    #expect(h.model.rowItems.contains { $0.statusLabel == "New transfer" && $0.account == "PKO USD → PKO Personal" })
  }

  // MARK: Events from tags (R-IMP-SALDO-4)

  @Test("R-IMP-SALDO-4: ticked tags become events on commit; unticked ones do not")
  func tagsToEvents() async throws {
    let h = ImportHarness(database: try PreviewData.database())
    await h.model.load()
    await h.model.open(data: ImportSamples.saldo, fileName: ImportSamples.saldoFileName)
    let model = h.model
    #expect(model.eventItems.map(\.tag) == ["Trip 2025", "Relocation", "City break 2025"])
    #expect(model.eventItems.map(\.isSelected) == [false, true, false])
    #expect(model.eventItems[0].count == "2 transactions")
    #expect(model.eventItems[0].range == "May 2025")
    #expect(model.eventItems[1].note == "Goes to the existing event")

    model.setEvent(tag: "Trip 2025", selected: true)
    #expect(model.eventItems[0].isSelected)
    #expect(model.rowItems.first { $0.payee == "MUSEUM" }?.detail.contains("tag “Trip 2025” → event") == true)
    model.acceptSuggestions()
    let before = try await h.events().count
    await model.commit()
    #expect(model.step == .done)
    let events = try await h.events()
    #expect(events.count == before + 1)
    let trip = try #require(events.first { $0.name == "Trip 2025" })
    let tripTxns = try await h.txns().filter { $0.txn.eventID == trip.id }
    #expect(tripTxns.count == 2)
    #expect(try await h.txns().filter { $0.txn.eventID == PreviewData.relocation.id && $0.txn.payee == "Movers" }.count == 1)
    #expect(!events.contains { $0.name == "City break 2025" })
  }

  // MARK: Needs review (R-IMP-5)

  @Test("R-IMP-5: review rows block the import until decided; the suggestions resolve them")
  func reviewBlocks() async throws {
    let h = try await ImportHarness.empty()
    try await h.open("saldo", "pairing")
    let model = h.model
    let open = try #require(model.preview?.counts.needsReview)
    #expect(open > 0)
    #expect(model.unresolvedReviewCount == open)
    #expect(!model.canCommit)
    #expect(model.blockingNote?.contains("in Needs review still") == true)
    #expect(model.reviewItems.allSatisfy { $0.selected == nil })
    #expect(model.rowItems.filter { $0.status == .needsReview }.allSatisfy { $0.note == ImportNote("Decide in Needs review", .attention) })

    model.acceptSuggestions()
    #expect(model.unresolvedReviewCount == 0)
    #expect(model.reviewItems.allSatisfy { $0.selected == $0.suggested })
    #expect(model.canCommit)
    #expect(model.blockingNote == nil)
  }

  @Test("R-IMP-5, R-IMP-SALDO-2, D26: pair two halves, record one with a category, skip one, through the review options")
  func reviewChoices() async throws {
    let h = ImportHarness(database: try PreviewData.database())
    await h.model.load()
    await h.model.open(data: ImportSamples.saldo, fileName: ImportSamples.saldoFileName)
    let model = h.model
    #expect(model.reviewItems.count == 4)
    let out = try #require(model.reviewItems.first { $0.title.hasSuffix("To the USD card") })
    #expect(out.title.hasPrefix("Outgoing transfer half without a match"))
    #expect(out.detail.contains("Saldo hints the other side is “Bank USD card”"))
    #expect(out.options.map(\.label) == ["Pair with", "Record as expense", "Debt…", "Skip"])
    // Different transit currencies: offered, not suggested (D26).
    #expect(out.suggested == .record(.expense))
    #expect(out.pairCandidates.count == 1)

    model.selectReviewOption(.pair, forRow: out.id)
    let paired = try #require(model.reviewItems.first { $0.id == out.id })
    #expect(paired.selected == .pair)
    let partnerID = try #require(out.pairCandidates.first.flatMap { if case .pair(let id) = $0.choice { id } else { nil } })
    #expect(model.reviewItems.first { $0.id == partnerID }?.selected == .pair)

    let sent = try #require(model.reviewItems.first { $0.title.hasSuffix("Money sent") })
    #expect(sent.options.first?.isEnabled == false)
    model.selectReviewOption(.record(.expense), forRow: sent.id)
    let fees = PreviewData.categories.first { $0.name == "Fees" }!.id
    model.selectReviewCategory(fees, forRow: sent.id)
    #expect(model.reviewItems.first { $0.id == sent.id }?.selectedCategory == fees)
    #expect(!model.canCommit)

    let cash = try #require(model.reviewItems.first { $0.title.hasSuffix("Into EUR cash") })
    model.selectReviewOption(.skip, forRow: cash.id)
    #expect(model.unresolvedReviewCount == 0)
    #expect(model.canCommit)

    await model.commit()
    #expect(model.step == .done)
    let txns = try await h.txns()
    let transfer = try #require(txns.first { $0.txn.payee == "To the USD card" })
    #expect(transfer.txn.type == .transfer)
    #expect(transfer.txn.amountMinor == 1200_00)
    #expect(transfer.txn.toAmountMinor == 30_00)
    let gift = try #require(txns.first { $0.txn.payee == "Money sent" })
    #expect(gift.txn.type == .expense && gift.txn.categoryID == fees)
    #expect(!txns.contains { $0.txn.payee == "Into EUR cash" })
    #expect(model.doneLines.contains { $0.contains("4 reviewed rows resolved") })
  }

  @Test("R-IMP-5: an unknown PKO operation type can be recorded as a transfer to an own account")
  func reviewTransfer() async throws {
    let h = ImportHarness(database: try PreviewData.database())
    await h.model.load()
    await h.model.open(data: ImportSamples.pko, fileName: ImportSamples.pkoFileName)
    await h.model.chooseTargetAccount(PreviewData.pkoPersonal.id)
    let model = h.model
    let fee = try #require(model.reviewItems.first)
    #expect(fee.title == "Unknown operation type")
    #expect(fee.options.map(\.label) == ["Expense", "Transfer to my account", "Debt…", "Skip"])
    #expect(!fee.transferAccounts.contains { $0.id == PreviewData.pkoPersonal.id })
    #expect(!fee.transferAccounts.contains { $0.id == PreviewData.oldCard.id })
    model.selectReviewOption(.transfer, forRow: fee.id)
    model.selectTransferAccount(PreviewData.pkoCreditCard.id, forRow: fee.id)
    let chosen = try #require(model.reviewItems.first { $0.id == fee.id })
    #expect(chosen.selected == .transfer)
    #expect(chosen.selectedTransferAccount == PreviewData.pkoCreditCard.id)
    #expect(model.rowItems.first { $0.id == fee.id }?.note == ImportNote("Decided in Needs review"))
    await model.commit()
    let txn = try #require(try await h.txns().first { $0.txn.payee == "OPŁATA MIESIĘCZNA" }?.txn)
    #expect(txn.type == .transfer)
    #expect(txn.toAccountID == PreviewData.pkoCreditCard.id)
  }

  // MARK: Commit, done, history, undo (R-IMP-6)

  @Test("R-IMP-6: commit writes everything, shows the summary and lists the batch; undo after confirmation removes it")
  func commitAndUndo() async throws {
    let h = try await ImportHarness.empty()
    let model = h.model
    final class Counter { var value = 0 }
    let changes = Counter()
    model.onDataChanged = { changes.value += 1 }
    try await h.open("saldo", "spec-example")
    await model.commit()
    #expect(model.step == .done)
    #expect(model.doneTitle == "Saldo history imported")
    #expect(model.doneLines.first == "3 transactions imported · 1 transfer paired")
    #expect(model.historyItems.count == 1)
    #expect(model.historyItems[0].file == "spec-example.csv")
    #expect(model.historyItems[0].summary.hasPrefix("Saldo · 3 new"))
    #expect(try await h.txns().count == 3)
    #expect(changes.value == 1)

    model.requestUndoOfLastImport()
    #expect(model.pendingUndo?.fileName == "spec-example.csv")
    #expect(model.undoConfirmationTitle == "Undo the import of “spec-example.csv”?")
    model.cancelUndo()
    #expect(model.pendingUndo == nil)
    #expect(try await h.txns().count == 3)

    model.requestUndoOfLastImport()
    await model.confirmUndo()
    #expect(try await h.txns().isEmpty)
    #expect(try await h.accounts().isEmpty)
    #expect(model.step == .chooseFile)
    #expect(model.isHistoryShown)
    #expect(model.historyItems[0].isUndone)
    #expect(changes.value == 2)
    // An undone batch can't be undone again.
    model.requestUndo(model.historyItems[0].batch)
    #expect(model.pendingUndo == nil)
  }

  @Test("R-IMP-6: undo from the history panel keeps the wizard where it is")
  func undoFromHistory() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount])
    try await h.open("pko", "settled-later")
    await h.model.chooseTargetAccount(pkoAccount.id)
    await h.model.commit()
    h.model.cancel()
    try await h.open("saldo", "spec-example")
    #expect(h.model.step == .review)
    let pkoBatch = try #require(h.model.historyItems.first { $0.file == "settled-later.csv" })
    h.model.requestUndo(pkoBatch.batch)
    await h.model.confirmUndo()
    #expect(h.model.step == .review)
    #expect(h.model.historyItems.first { $0.id == pkoBatch.id }?.isUndone == true)
    #expect(try await h.txns().isEmpty)
  }

  @Test("R-IMP-6: a failing commit saves nothing, explains why and keeps the review")
  func commitFailure() async throws {
    let h = try await ImportHarness.empty(store: { FailingCommitStore(base: SQLiteImportStore(database: $0, calendar: ImportHarness.calendar)) })
    try await h.open("saldo", "spec-example")
    await h.model.commit()
    #expect(h.model.step == .review)
    #expect(h.model.errorMessage == "Nothing was saved: The disk is full.")
    #expect(h.model.preview != nil)
    #expect(h.model.activity == .idle)
    #expect(try await h.txns().isEmpty)
    #expect(h.model.historyItems.isEmpty)
  }

  @Test("R-IMP-3: re-importing the same file finds nothing new; Import is disabled")
  func reimport() async throws {
    let h = try await ImportHarness.empty()
    try await h.open("saldo", "spec-example")
    await h.model.commit()
    h.model.cancel()
    try await h.open("saldo", "spec-example")
    #expect(h.model.preview?.counts.new == 0)
    #expect(h.model.preview?.counts.alreadyImported == 3)
    #expect(h.model.cards.map(\.label).contains("Already imported"))
    #expect(!h.model.canCommit)
    #expect(h.model.commitLabel == "Import")
    #expect(h.model.blockingNote == "Nothing new in this file.")
  }

  @Test("R-IMP-PKO-2: a later statement settles the imported hold")
  func settlesPending() async throws {
    let h = try await ImportHarness.empty(accounts: [pkoAccount])
    try await h.open("pko", "all-types")
    await h.model.chooseTargetAccount(pkoAccount.id)
    h.model.acceptSuggestions()
    await h.model.commit()
    h.model.cancel()
    try await h.open("pko", "settled-later")
    let settle = try #require(h.model.rowItems.first { $0.status == .settlesPending })
    #expect(settle.statusLabel == "Settles pending")
    #expect(settle.note == ImportNote("Updates the pending payment"))
    #expect(h.model.cards.first { $0.status == .settlesPending }?.count == "1")
    #expect(h.model.canCommit)
    await h.model.commit()
    #expect(h.model.doneLines.contains { $0.contains("1 pending payment settled") })
    #expect(h.model.doneTitle == "PKO statement imported")
  }

  @Test("Cancel returns to step 1 without saving anything")
  func cancel() async throws {
    let h = try await ImportHarness.empty()
    try await h.open("saldo", "spec-example")
    h.model.cancel()
    #expect(h.model.step == .chooseFile)
    #expect(h.model.preview == nil)
    #expect(h.model.file == nil)
    #expect(try await h.txns().isEmpty)
  }

  // MARK: Preview world

  @Test("Preview world: the samples show every status, mapping and review case for the screenshots")
  func previewWorld() async throws {
    let dependencies = try await ImportWizardDependencies.preview()
    let model = ImportWizardModel(dependencies: dependencies)
    await model.load()
    #expect(model.historyItems.map(\.isUndone) == [false, true])
    await model.open(data: ImportSamples.pko, fileName: ImportSamples.pkoFileName)
    #expect(model.targetRemembered)
    let counts = try #require(model.preview?.counts)
    #expect(counts.new > 0 && counts.alreadyImported == 1 && counts.possibleDuplicate == 1)
    #expect(counts.settlesPending == 1 && counts.needsReview == 1)
    #expect(model.rowItems.contains { $0.note?.text.hasPrefix("By rule") == true })

    model.cancel()
    await model.open(data: ImportSamples.saldo, fileName: ImportSamples.saldoFileName)
    #expect(model.reviewItems.count == 4)
    #expect(model.eventItems.count == 3)
    #expect(model.mappingGroups[0].items.contains { $0.note == ImportNote("Created archived") })
    #expect(model.mappingGroups[0].items.contains { $0.note == ImportNote("Liability → Debt account") })
  }
}
