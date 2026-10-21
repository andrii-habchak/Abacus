import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// Pipeline behaviour on fakes (R-IMP-1, 2, 5, 6, 7; R-IMP-SALDO-3/4; R-IMP-PKO-1/3; R-CUR-4;
/// R-TX-6; R-ACC-2/4). Synthetic data only.
@Suite("Import pipeline")
struct PipelineTests {
  typealias F = PipelineFixture

  // MARK: Detection

  @Test("R-IMP-1: the format is detected from the file")
  func detection() throws {
    #expect(ImportPipeline.detect(try F.data("saldo", "spec-example")) == .saldo)
    #expect(ImportPipeline.detect(try F.data("pko", "all-types")) == .pko)
    #expect(ImportPipeline.detect(Data("a,b,c\n1,2,3\n".utf8)) == nil)
    #expect(ImportPipeline.statementCurrency(try F.data("pko", "all-types")) == .PLN)
  }

  @Test("R-IMP-1: an unknown file is refused before anything is parsed")
  func unknownFormat() async throws {
    let db = FakeDB()
    await #expect(throws: ImportPipelineError.unrecognisedFormat) {
      try await db.pipeline().preview(data: Data("hello".utf8), fileName: "x.csv")
    }
  }

  // MARK: Saldo preview

  @Test("R-IMP-1, R-IMP-SALDO-1: Saldo preview counts, date range and row types")
  func saldoPreview() async throws {
    let db = FakeDB()
    let preview = try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "saldo.csv")
    #expect(preview.source == .saldo)
    #expect(preview.rows.count == 4)
    #expect(preview.counts.new == 4)
    #expect(preview.counts.all == 4)
    #expect(preview.canCommit)
    #expect(preview.dateRange == Day("2025-03-01")!...Day("2025-03-04")!)
    let cafe = try #require(preview.row("saldo:1002"))
    #expect(cafe.type == .expense)
    #expect(cafe.categorySource == .file)
    let paired = try #require(preview.row("saldo:1004"))
    #expect(paired.type == .transfer)
    #expect(paired.detail == "Two transfer halves paired")
    #expect(preview.transactionsToCreate == 3)
  }

  @Test("R-IMP-2, R-ACC-2, R-ACC-4: new accounts get kinds from Saldo types and stay archived")
  func saldoAccountsCreated() async throws {
    let db = FakeDB()
    let data = F.saldo([
      "1,2025-01-01T10:00:00,Lent,Bank PLN,BANK_ACCOUNTS,0,CREDIT,50.00,PLN",
      "1,2025-01-01T10:00:00,Lent,Friend PLN,LIABILITIES,0,DEBIT,50.00,PLN",
      "2,2025-01-02T10:00:00,Coffee,Old card,BANK_ACCOUNTS,1,CREDIT,5.00,PLN",
      "2,2025-01-02T10:00:00,Coffee,Eating out,EXPENSES,0,DEBIT,5.00,PLN",
      "3,2025-01-03T10:00:00,Broker,Bank PLN,BANK_ACCOUNTS,0,CREDIT,10.00,PLN",
      "3,2025-01-03T10:00:00,Broker,Broker PLN,OTHER_ASSETS,0,DEBIT,10.00,PLN",
      "4,2025-01-04T10:00:00,Lunch,Wallet,CASH,0,CREDIT,7.00,PLN",
      "4,2025-01-04T10:00:00,Lunch,Eating out,EXPENSES,0,DEBIT,7.00,PLN",
    ])
    let preview = try await db.pipeline().preview(data: data, fileName: "s.csv")
    let byName = Dictionary(uniqueKeysWithValues: preview.accountMappings.map { ($0.external.name, $0) })
    #expect(byName["Friend PLN"]?.newKind == .debt)
    #expect(byName["Broker PLN"]?.newKind == .investment)
    #expect(byName["Wallet"]?.newKind == .cash)
    #expect(byName["Old card"]?.newIsArchived == true)
    #expect(preview.accountMappings.allSatisfy { $0.target == .create && $0.origin == .new })

    let summary = try await db.pipeline().commit(preview)
    #expect(summary.accountsCreated == 5)
    #expect(summary.categoriesCreated == 1)
    let old = try #require(db.accounts.first { $0.name == "Old card" })
    #expect(old.isArchived)
    #expect(db.accounts.first { $0.name == "Friend PLN" }?.kind == .debt)
  }

  @Test("R-IMP-2: same name and currency maps to the existing account and category; remembered next time")
  func mappingSameNameAndRemembered() async throws {
    let db = FakeDB()
    let bank = Account(id: F.id(5), name: "bank pln", currency: .PLN, kind: .bank, openingDate: F.date("2024-01-01"))
    let renamed = Account(id: F.id(6), name: "Main card", currency: .PLN, kind: .card, openingDate: F.date("2024-01-01"))
    db.accounts = [bank, renamed, F.pkoUSD]
    db.categories = [F.groceries]
    let data = F.saldo([
      "1,2025-01-01T10:00:00,Shop,Bank PLN,BANK_ACCOUNTS,0,CREDIT,5.00,PLN",
      "1,2025-01-01T10:00:00,Shop,Groceries,EXPENSES,0,DEBIT,5.00,PLN",
    ])
    let pipeline = db.pipeline()
    var preview = try await pipeline.preview(data: data, fileName: "s.csv")
    #expect(preview.accountMappings[0].target == .existing(bank.id))
    #expect(preview.accountMappings[0].origin == .sameName)
    #expect(preview.categoryMappings[0].target == .existing(F.groceries.id))

    // The user maps it elsewhere; the choice is remembered.
    preview = try await pipeline.remapAccount(preview, key: "Bank PLN|PLN", to: .existing(renamed.id))
    #expect(preview.rows[0].account == .existing(renamed.id))
    await #expect(throws: ImportPipelineError.currencyMismatch) {
      try await pipeline.remapAccount(
        preview, key: "Bank PLN|PLN",
        to: .existing(F.pkoUSD.id))
    }
    try await pipeline.commit(preview)
    #expect(db.mappings.contains { $0.kind == .account && $0.externalKey == "Bank PLN|PLN" && $0.targetID == renamed.id })
    #expect(db.txns.first?.accountID == renamed.id)

    let next = try await pipeline.preview(
      data: F.saldo([
        "2,2025-01-02T10:00:00,Shop,Bank PLN,BANK_ACCOUNTS,0,CREDIT,6.00,PLN",
        "2,2025-01-02T10:00:00,Shop,Groceries,EXPENSES,0,DEBIT,6.00,PLN",
      ]), fileName: "s2.csv")
    #expect(next.accountMappings[0].target == .existing(renamed.id))
    #expect(next.accountMappings[0].origin == .remembered)
    #expect(next.categoryMappings[0].origin == .remembered)
  }

  @Test("R-IMP-2: a source category can be mapped to another existing category of the same kind")
  func categoryRemap() async throws {
    let db = FakeDB()
    let food = AbacusDomain.Category(id: F.id(30), name: "Food", kind: .expense)
    db.categories = [food, F.salary]
    var preview = try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "s.csv")
    try preview.mapCategory(key: "expense|Eating out", to: .existing(food.id))
    #expect(preview.row("saldo:1002")?.category == .existing(food.id))
    #expect(throws: ImportPipelineError.self) { try preview.mapCategory(key: "expense|Eating out", to: .existing(F.salary.id)) }
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.categoriesCreated == 1)  // Fees only
    #expect(db.txns.first { $0.payee == "CAFE" }?.categoryID == food.id)
  }

  @Test("R-IMP-SALDO-3, R-IMP-7: opening balances only for accounts the import creates")
  func openingBalances() async throws {
    let db = FakeDB()
    let existingUSD = Account(
      id: F.id(7), name: "Bank USD", currency: .USD, kind: .bank, openingBalanceMinor: 5_00, openingDate: F.date("2024-01-01"))
    db.accounts = [existingUSD]
    let data = F.saldo([
      "1,2025-03-01T10:00:00,Initial balance,Bank UAH,BANK_ACCOUNTS,0,DEBIT,1000.00,UAH",
      "1,2025-03-01T10:00:00,Initial balance,Initial balance,EQUITY,0,CREDIT,1000.00,UAH",
      "2,2025-03-01T10:00:00,Initial balance,Bank USD,BANK_ACCOUNTS,0,DEBIT,70.00,USD",
      "2,2025-03-01T10:00:00,Initial balance,Initial balance,EQUITY,0,CREDIT,70.00,USD",
      "3,2025-02-27T10:00:00,Coffee,Bank UAH,BANK_ACCOUNTS,0,CREDIT,40.00,UAH",
      "3,2025-02-27T10:00:00,Coffee,Eating out,EXPENSES,0,DEBIT,40.00,UAH",
    ])
    let preview = try await db.pipeline().preview(data: data, fileName: "s.csv")
    #expect(preview.row("saldo:1")?.status == .new)
    #expect(preview.row("saldo:2")?.status == .skipped)
    #expect(preview.counts.skipped == 1)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.openingBalancesSet == 1)
    let uah = try #require(db.accounts.first { $0.name == "Bank UAH" })
    #expect(uah.openingBalanceMinor == 1000_00)
    // Opening date: the first day the file touches the account.
    #expect(uah.openingDate == F.calendar.startOfDay(for: F.date("2025-02-27")))
    #expect(db.accounts.first { $0.id == existingUSD.id }?.openingBalanceMinor == 5_00)
    #expect(db.balance(uah.id) == 960_00)
  }

  @Test("R-CUR-4, R-TX-6, D22: original amounts, fees and refund lines become transaction fields and attached records")
  func linesAndOriginals() async throws {
    let db = FakeDB()
    let patterns = try F.data("saldo", "patterns")
    var preview = try await db.pipeline().preview(data: patterns, fileName: "p.csv")
    preview.acceptSuggestedReviewChoices()
    try await db.pipeline().commit(preview)

    let bistro = try #require(db.txn(fingerprint: "saldo:2002"))
    #expect(bistro.amountMinor == 43_10)
    #expect(bistro.originalAmountMinor == 10_00)
    #expect(bistro.originalCurrencyCode == "EUR")

    let split = try #require(db.txn(fingerprint: "saldo:2004"))
    let splitLines = db.lines.filter { $0.txnID == split.id }
    #expect(splitLines.count == 1)
    #expect(split.amountMinor + splitLines.map(\.amountMinor).reduce(0, +) == 100_00)

    let fee = try #require(db.txn(fingerprint: "saldo:2009"))
    #expect(fee.type == .transfer)
    let feeLine = try #require(db.lines.first { $0.txnID == fee.id })
    #expect(feeLine.kind == .expense)
    #expect(feeLine.amountMinor == 10_00)
    #expect(db.categories.first { $0.id == feeLine.categoryID }?.name == "Fees")

    // D22: the refund leg of a transfer is an income line in the expense category.
    let refund = try #require(db.txn(fingerprint: "saldo:2025"))
    let refundLine = try #require(db.lines.first { $0.txnID == refund.id })
    #expect(refundLine.kind == .income)
    #expect(db.categories.first { $0.id == refundLine.categoryID }?.kind == .expense)

    // R-TX-4: Saldo refund keeps its expense category.
    let groceryReturn = try #require(db.txn(fingerprint: "saldo:2014"))
    #expect(groceryReturn.type == .expense && groceryReturn.isRefund)
  }

  @Test("R-IMP-SALDO-4: ticked tags become events, unticked ones are ignored")
  func tagsToEvents() async throws {
    let db = FakeDB()
    var preview = try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "s.csv")
    let candidate = try #require(preview.eventCandidates.first)
    #expect(candidate.tag == "Trip 2025")
    #expect(candidate.rowCount == 1)
    #expect(!candidate.isSelected)
    preview.setEvent(tag: "Trip 2025", selected: true)
    #expect(preview.row("saldo:1002")?.eventTag == "Trip 2025")
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.eventsCreated == 1)
    let event = try #require(db.events.first)
    #expect(event.name == "Trip 2025")
    #expect(event.startDay == "2025-03-02")
    #expect(db.txn(fingerprint: "saldo:1002")?.eventID == event.id)
    #expect(db.txns.filter { $0.eventID != nil }.count == 1)
  }

  @Test("R-IMP-SALDO-4, R-EVT-2: a tag named like an existing event goes to that event")
  func tagToExistingEvent() async throws {
    let db = FakeDB()
    let trip = Event(id: F.id(40), name: "trip 2025")
    db.events = [trip]
    let preview = try await db.pipeline().preview(data: F.data("saldo", "spec-example"), fileName: "s.csv")
    #expect(preview.eventCandidates.first?.existingEventID == trip.id)
    #expect(preview.eventCandidates.first?.isSelected == true)
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.eventsCreated == 0)
    #expect(db.txn(fingerprint: "saldo:1002")?.eventID == trip.id)
  }

  // MARK: Needs review

  @Test("R-IMP-5, R-IMP-SALDO-2, D26: unpaired halves wait for a choice; nothing commits before")
  func reviewBlocksCommit() async throws {
    let db = FakeDB()
    let preview = try await db.pipeline().preview(data: F.data("saldo", "pairing"), fileName: "pairing.csv")
    #expect(preview.counts.needsReview > 0)
    #expect(preview.unresolvedReviewCount == preview.counts.needsReview)
    #expect(!preview.canCommit)
    await #expect(throws: ImportPipelineError.self) { try await db.pipeline().commit(preview) }
    #expect(db.commits.isEmpty)
  }

  @Test("R-IMP-5: pair two halves by hand, record one as expense, skip another")
  func reviewChoices() async throws {
    let db = FakeDB()
    let data = F.saldo([
      // A cross-currency transfer whose halves book the transit in different currencies (D26).
      "1,2025-05-01T10:00:00,To EUR,Bank UAH,BANK_ACCOUNTS,0,CREDIT,4400.00,UAH",
      "1,2025-05-01T10:00:00,To EUR,Bank EUR,MONEY_ON_THE_WAY,0,DEBIT,4400.00,UAH",
      "2,2025-05-01T10:01:00,From UAH,Bank EUR,BANK_ACCOUNTS,0,DEBIT,100.00,EUR",
      "2,2025-05-01T10:01:00,From UAH,Bank UAH,MONEY_ON_THE_WAY,0,CREDIT,100.00,EUR",
      // Money sent to someone.
      "3,2025-05-03T10:00:00,To a friend,Bank UAH,BANK_ACCOUNTS,0,CREDIT,200.00,UAH",
      "3,2025-05-03T10:00:00,Money on the way,Money on the way,MONEY_ON_THE_WAY,0,DEBIT,200.00,UAH",
      "4,2025-05-20T10:00:00,Unknown,Bank EUR,BANK_ACCOUNTS,0,DEBIT,3.00,EUR",
      "4,2025-05-20T10:00:00,Unknown,Money on the way,MONEY_ON_THE_WAY,0,CREDIT,3.00,EUR",
    ])
    db.categories = [AbacusDomain.Category(id: F.id(50), name: "Gifts", kind: .expense)]
    var preview = try await db.pipeline().preview(data: data, fileName: "r.csv")
    #expect(preview.counts.needsReview == 4)
    let out = try #require(preview.row("saldo:1")?.review)
    #expect(out.reason == .unpairedTransferHalf(.outgoing))
    #expect(out.pairRows.first == "saldo:2")
    // Different transit currencies: offered, not suggested (D26).
    #expect(out.suggested == .record(.expense, categoryID: nil))

    preview.setReviewChoice(.pair(rowID: "saldo:2"), forRow: "saldo:1")
    #expect(preview.row("saldo:2")?.review?.choice == .pair(rowID: "saldo:1"))
    preview.setReviewChoice(.record(.expense, categoryID: F.id(50)), forRow: "saldo:3")
    #expect(!preview.canCommit)
    preview.setReviewChoice(.skip, forRow: "saldo:4")
    #expect(preview.canCommit)
    #expect(preview.transactionsToCreate == 2)

    let summary = try await db.pipeline().commit(preview)
    #expect(summary.created == 2)
    #expect(summary.transfersPaired == 1)
    #expect(summary.reviewedImported == 3)
    #expect(summary.reviewedSkipped == 1)
    let transfer = try #require(db.txn(fingerprint: "saldo:1"))
    #expect(db.txn(fingerprint: "saldo:2")?.id == transfer.id)
    #expect(transfer.type == .transfer)
    #expect(transfer.amountMinor == 4400_00)
    #expect(transfer.toAmountMinor == 100_00)
    let gift = try #require(db.txn(fingerprint: "saldo:3"))
    #expect(gift.type == .expense && gift.categoryID == F.id(50))
    #expect(db.txn(fingerprint: "saldo:4") == nil)
  }

  @Test("R-IMP-5: re-pairing clears the previous partner; recording money in as expense keeps the balance")
  func reviewRepairAndDirection() async throws {
    let db = FakeDB()
    let data = F.saldo([
      "1,2025-05-01T10:00:00,Out,Bank A,BANK_ACCOUNTS,0,CREDIT,10.00,PLN",
      "1,2025-05-01T10:00:00,Out,Bank B,MONEY_ON_THE_WAY,0,DEBIT,11.00,PLN",
      "2,2025-05-01T10:00:00,In,Bank B,BANK_ACCOUNTS,0,DEBIT,11.00,PLN",
      "2,2025-05-01T10:00:00,In,Bank A,MONEY_ON_THE_WAY,0,CREDIT,10.00,PLN",
      "3,2025-05-02T10:00:00,In too,Bank C,BANK_ACCOUNTS,0,DEBIT,7.00,PLN",
      "3,2025-05-02T10:00:00,In too,Bank A,MONEY_ON_THE_WAY,0,CREDIT,7.00,PLN",
    ])
    var preview = try await db.pipeline().preview(data: data, fileName: "r.csv")
    preview.setReviewChoice(.pair(rowID: "saldo:2"), forRow: "saldo:1")
    preview.setReviewChoice(.pair(rowID: "saldo:1"), forRow: "saldo:3")
    #expect(preview.row("saldo:2")?.review?.choice == nil)
    preview.setReviewChoice(.record(.expense, categoryID: nil), forRow: "saldo:2")
    try await db.pipeline().commit(preview)
    let b = try #require(db.accounts.first { $0.name == "Bank B" })
    let refund = try #require(db.txn(fingerprint: "saldo:2"))
    #expect(refund.isRefund)
    #expect(db.balance(b.id) == 11_00)
  }

  @Test("R-IMP-5: an incoming half can pair with an existing expense on another account")
  func pairWithExisting() async throws {
    let db = FakeDB()
    let eur = Account(id: F.id(8), name: "Card EUR", currency: .EUR, kind: .card, openingDate: F.date("2024-01-01"))
    let wallet = Account(id: F.id(9), name: "Wallet EUR", currency: .EUR, kind: .cash, openingDate: F.date("2024-01-01"))
    db.accounts = [eur, wallet]
    let sent = Txn(type: .expense, occurredAt: F.date("2025-03-09"), accountID: eur.id, amountMinor: 300_00, payee: "Sent", source: .manual)
    db.txns = [sent]
    let data = F.saldo([
      "1,2025-03-10T10:00:00,Received,Wallet EUR,BANK_ACCOUNTS,0,DEBIT,300.00,EUR",
      "1,2025-03-10T10:00:00,Received,Money on the way,MONEY_ON_THE_WAY,0,CREDIT,300.00,EUR",
    ])
    var preview = try await db.pipeline().preview(data: data, fileName: "r.csv")
    let review = try #require(preview.row("saldo:1")?.review)
    #expect(review.pairExisting.map(\.id) == [sent.id])
    #expect(review.suggested == .pairExisting(sent.id))
    preview.acceptSuggestedReviewChoices()
    let summary = try await db.pipeline().commit(preview)
    #expect(summary.transfersCompleted == 1)
    #expect(summary.created == 0)
    let converted = try #require(db.txns.first { $0.id == sent.id })
    #expect(converted.type == .transfer)
    #expect(converted.toAccountID == wallet.id)
    #expect(converted.toAmountMinor == 300_00)
    #expect(converted.categoryID == nil)
    #expect(db.txn(fingerprint: "saldo:1")?.id == sent.id)
    #expect(db.balance(wallet.id) == 300_00)
  }

  // MARK: PKO

  @Test("R-IMP-PKO-1: a statement needs a target account; the choice is remembered per currency")
  func pkoTargetAccount() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let data = try F.data("pko", "settled-later")
    await #expect(throws: ImportPipelineError.targetAccountRequired(currency: .PLN)) {
      try await db.pipeline().preview(data: data, fileName: "pko.csv")
    }
    let preview = try await db.pipeline().preview(data: data, fileName: "pko.csv", targetAccountID: F.pkoAccount.id)
    #expect(!preview.targetRemembered)
    try await db.pipeline().commit(preview)
    #expect(try await db.pipeline().rememberedTargetAccount(for: data) == F.pkoAccount.id)
    let again = try await db.pipeline().preview(data: data, fileName: "pko.csv")
    #expect(again.targetAccountID == F.pkoAccount.id)
    #expect(again.targetRemembered)
    #expect(again.counts.alreadyImported == 2)
  }

  @Test("R-IMP-PKO-3: rows become expense, income, refund and ATM transfer; original amount kept")
  func pkoRows() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount]
    let preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "pko.csv", targetAccountID: F.pkoAccount.id)
    #expect(preview.rows.count == 13)
    // The exchange (other account unknown) and the unknown type wait for review.
    #expect(preview.counts.needsReview == 2)
    #expect(preview.counts.new == 11)

    let atm = try #require(preview.rows.first { $0.source.payee.contains("BANKOMAT") })
    #expect(atm.type == .transfer)
    let cash = try #require(preview.accountMappings.first { $0.external.name == PKOParser.cashAccountName })
    #expect(cash.newName == "Cash PLN")
    #expect(cash.newKind == .cash)
    #expect(atm.counterAccount == .new(key: cash.id))

    let unknown = try #require(preview.rows.first { $0.review?.reason == .unknownOperationType })
    #expect(unknown.review?.suggested == .record(.expense, categoryID: nil))

    var ready = preview
    ready.acceptSuggestedReviewChoices()
    let summary = try await db.pipeline().commit(ready)
    #expect(summary.created == 13)
    #expect(summary.accountsCreated == 1)
    let museum = try #require(db.txns.first { $0.payee.contains("MUZEUM") })
    #expect(museum.originalAmountMinor == 10_50)
    #expect(museum.originalCurrencyCode == "EUR")
    #expect(museum.bookedDay == "2026-01-14")
    #expect(museum.occurredAt == F.calendar.startOfDay(for: F.date("2026-01-12")))
    let refund = try #require(db.txns.first { $0.amountMinor == 17_35 && $0.isRefund })
    #expect(refund.type == .expense)
    let hold = try #require(db.txns.first { $0.isPendingAtBank })
    #expect(hold.amountMinor == 23_40)
    #expect(hold.bookedDay == nil)
    #expect(db.txns.allSatisfy { $0.source == .pko })
  }

  @Test("R-IMP-PKO-3: ATM withdrawals go to the existing cash account, remembered after the import")
  func pkoCashRemembered() async throws {
    let db = FakeDB()
    let wallet = Account(id: F.id(12), name: "Wallet", currency: .PLN, kind: .cash, openingDate: F.date("2024-01-01"))
    db.accounts = [F.pkoAccount, wallet]
    let preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "pko.csv", targetAccountID: F.pkoAccount.id)
    let cash = try #require(preview.accountMappings.first)
    #expect(cash.target == .existing(wallet.id))
    #expect(cash.origin == .cashAccount)
    var ready = preview
    ready.acceptSuggestedReviewChoices()
    try await db.pipeline().commit(ready)
    #expect(db.mappings.contains { $0.source == .pko && $0.externalKey == "Cash|PLN" && $0.targetID == wallet.id })
    #expect(db.balance(wallet.id) == 200_00)
  }

  @Test("R-IMP-PKO-3: a counterparty account number of an own account turns the row into a transfer")
  func pkoOwnAccountTransfer() async throws {
    let db = FakeDB()
    var usd = F.pkoUSD
    usd.iban = "PL44 4444 4444 4444 4444 4444 4444"
    db.accounts = [F.pkoAccount, usd]
    let preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "pko.csv", targetAccountID: F.pkoAccount.id)
    let exchange = try #require(preview.rows.first { $0.source.kind == .transferHalf })
    #expect(exchange.status == .new)
    #expect(exchange.type == .transfer)
    #expect(exchange.counterAccount == .existing(usd.id))
    #expect(preview.counts.needsReview == 1)

    var ready = preview
    ready.acceptSuggestedReviewChoices()
    try await db.pipeline().commit(ready)
    let transfer = try #require(db.txns.first { $0.type == .transfer && $0.accountID == usd.id })
    #expect(transfer.toAccountID == F.pkoAccount.id)
    #expect(transfer.amountMinor == 1000_00)
    #expect(transfer.toAmountMinor == 3650_00)
    #expect(db.balance(usd.id) == -1000_00)
  }

  @Test("R-IMP-PKO-3: own-account transfer pairs with the other side already imported")
  func pkoOwnTransferPairsWithOtherSide() async throws {
    let db = FakeDB()
    let savings = Account(
      id: F.id(13), name: "PKO Savings", currency: .PLN, kind: .savings, openingDate: F.date("2024-01-01"),
      iban: "11111111111111111111111111")
    var personal = F.pkoAccount
    personal.iban = "PL 22 2222 2222 2222 2222 2222 2222"
    db.accounts = [personal, savings]
    // The savings statement was imported first: money in from PKO Personal recorded as income.
    let other = Txn(
      type: .income, occurredAt: F.date("2026-01-10"), accountID: savings.id, amountMinor: 1500_00, payee: "Personal",
      source: .pko)
    db.txns = [other]
    db.fingerprints["pko:other"] = ImportFingerprint(id: "pko:other", txnID: other.id)
    let preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "pko.csv", targetAccountID: personal.id)
    let rent = try #require(preview.rows.first { $0.source.amountMinor == 1500_00 })
    #expect(rent.type == .transfer)
    #expect(rent.detail?.hasPrefix("Completes the transfer") == true)
    #expect(!rent.createsTransaction)

    var ready = preview
    ready.acceptSuggestedReviewChoices()
    let summary = try await db.pipeline().commit(ready)
    #expect(summary.transfersCompleted == 1)
    let converted = try #require(db.txns.first { $0.id == other.id })
    #expect(converted.type == .transfer)
    #expect(converted.accountID == personal.id)
    #expect(converted.toAccountID == savings.id)
    #expect(db.txns.filter { $0.amountMinor == 1500_00 }.count == 1)
    #expect(db.balance(savings.id) == 1500_00)

    // The same transfer met again from the savings side links instead of duplicating.
    let fromSavings = F.pko([
      #""2026-01-10","2026-01-10","Przelew na konto","+1500.00","PLN","+1500.00","Rachunek nadawcy: 22 2222 2222 2222 2222 2222 2222","Nazwa nadawcy: ME","Tytuł: SAVINGS","","","""#
    ])
    let again = try await db.pipeline().preview(data: fromSavings, fileName: "savings.csv", targetAccountID: savings.id)
    #expect(again.rows[0].status == .alreadyImported)
    #expect(again.rows[0].detail == "The other account's statement already has this transfer")
  }

  // MARK: Commit

  @Test("R-IMP-6: one ImportCommit with batch, summary and fingerprints; undo and history go through the store")
  func commitShape() async throws {
    let db = FakeDB()
    let pipeline = db.pipeline()
    let preview = try await pipeline.preview(data: F.data("saldo", "spec-example"), fileName: "saldo.csv")
    let summary = try await pipeline.commit(preview)
    #expect(db.commits.count == 1)
    let commit = try #require(db.commits.first)
    #expect(commit.batch.id == preview.batchID)
    #expect(commit.batch.source == .saldo)
    #expect(commit.batch.fileName == "saldo.csv")
    #expect(commit.batch.importedAt == F.now)
    #expect(commit.batch.summary == "Saldo · 3 new · 4 accounts, 2 categories created")
    #expect(commit.txns.count == 3)
    #expect(Set(commit.fingerprints.map(\.id)) == ["saldo:1002", "saldo:1003", "saldo:1004", "saldo:1005"])
    #expect(commit.newAccounts.count == 4)
    #expect(commit.mappings.count == 6)
    #expect(summary.lines.first == "3 transactions imported · 1 transfer paired")

    let history = try await pipeline.history()
    #expect(history.map(\.id) == [preview.batchID])
    try await pipeline.undo(preview.batchID)
    #expect(db.txns.isEmpty)
    #expect(try await pipeline.history().first?.isUndone == true)
  }
}
