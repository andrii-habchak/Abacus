import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

/// Saldo-like rules (R-IMP-8, D44): description contains / exactly matches, amount bigger /
/// smaller than, only on an account → category or transfer. Synthetic data only.
@Suite("Saldo-like rules")
struct SaldoLikeRulesTests {
  typealias F = PipelineFixture

  static let food = AbacusDomain.Category(id: F.id(60), name: "Food", kind: .expense)
  static let debt = Account(
    id: F.id(5), name: "Friend debt", currency: .PLN, kind: .debt, openingDate: F.date("2026-01-01", 0))
  static let closed = Account(
    id: F.id(6), name: "Closed debt", currency: .PLN, kind: .debt, openingDate: F.date("2026-01-01", 0), isArchived: true)
  static let accounts = [F.pkoAccount, F.pkoUSD, debt, closed]
  static let categories = [F.groceries, F.taxi, F.salary, food]

  static func category(
    _ n: Int, _ pattern: String, _ category: AbacusDomain.Category, kind: RuleMatchKind = .contains,
    amount: (RuleAmountComparison, Int64)? = nil, account: Account.ID? = nil
  ) -> CategoryRule {
    CategoryRule(
      id: F.id(100 + n), pattern: pattern, matchKind: kind, amountComparison: amount?.0, amountMinor: amount?.1,
      accountID: account, categoryID: category.id, position: n)
  }

  static func transfer(
    _ n: Int, _ pattern: String, to target: Account, kind: RuleMatchKind = .contains,
    amount: (RuleAmountComparison, Int64)? = nil, account: Account.ID? = nil
  ) -> CategoryRule {
    CategoryRule(
      id: F.id(100 + n), pattern: pattern, matchKind: kind, amountComparison: amount?.0, amountMinor: amount?.1,
      accountID: account, action: .transfer, transferAccountID: target.id, position: n)
  }

  static func subject(_ text: String, _ amount: Int64? = nil, account: Account.ID? = F.pkoAccount.id, kind: CategoryKind = .expense) -> RuleSubject {
    RuleSubject(description: text, accountID: account, amountMinor: amount, kind: kind)
  }

  // MARK: Matcher

  @Test("R-IMP-8: contains and exactly fold case, diacritics and whitespace")
  func textConditions() {
    let matcher = RuleMatcher(
      rules: [Self.category(0, "Żabka", F.groceries, kind: .exactly), Self.category(1, "kiosk", Self.food)],
      categories: Self.categories)
    #expect(matcher.match(Self.subject("  ZABKA "))?.id == F.id(100))
    #expect(matcher.match(Self.subject("zabka  nano")) == nil)
    #expect(matcher.match(Self.subject("COFFEE   KIOSK 12"))?.id == F.id(101))
    #expect(matcher.match(Self.subject("Coffee shop")) == nil)
  }

  @Test("R-IMP-8: amount bigger / smaller than compare the absolute amount strictly; no amount, no match")
  func amountConditions() {
    let bigger = Self.category(0, "shop", F.groceries, amount: (.biggerThan, 100_00))
    let smaller = Self.category(1, "shop", Self.food, amount: (.smallerThan, 100_00))
    let matcher = RuleMatcher(rules: [bigger, smaller], categories: Self.categories)
    #expect(matcher.match(Self.subject("Shop", 100_01))?.id == bigger.id)
    #expect(matcher.match(Self.subject("Shop", -250_00))?.id == bigger.id)
    #expect(matcher.match(Self.subject("Shop", 99_99))?.id == smaller.id)
    #expect(matcher.match(Self.subject("Shop", 100_00)) == nil)
    #expect(matcher.match(Self.subject("Shop", nil)) == nil)
    #expect(matcher.match(Self.subject("Other", 500_00)) == nil)
  }

  @Test("R-IMP-8: description AND amount AND account must all hold")
  func andConditions() {
    let rule = Self.category(0, "rent", Self.food, amount: (.biggerThan, 1_000_00), account: F.pkoAccount.id)
    let matcher = RuleMatcher(rules: [rule], categories: Self.categories)
    #expect(matcher.match(Self.subject("RENT MARCH", 1_500_00)) != nil)
    #expect(matcher.match(Self.subject("RENT MARCH", 500_00)) == nil)
    #expect(matcher.match(Self.subject("RENT MARCH", 1_500_00, account: F.pkoUSD.id)) == nil)
    // An account the import creates has no id yet: a per-account rule does not match it.
    #expect(matcher.match(Self.subject("RENT MARCH", 1_500_00, account: nil)) == nil)
    #expect(matcher.match(Self.subject("Deposit", 1_500_00)) == nil)
  }

  @Test("R-IMP-8, D44: the first rule wins across actions; transfer rules need an active other account")
  func transferActions() {
    let toOwn = Self.transfer(0, "friend", to: F.pkoAccount)
    let toClosed = Self.transfer(1, "friend", to: Self.closed)
    let toDebt = Self.transfer(2, "friend", to: Self.debt)
    let byCategory = Self.category(3, "friend", Self.food)
    let matcher = RuleMatcher(rules: [toOwn, toClosed, toDebt, byCategory], categories: Self.categories, accounts: Self.accounts)
    #expect(matcher.match(Self.subject("Dinner with a friend"))?.id == toDebt.id)
    #expect(matcher.candidates(for: Self.subject("Dinner with a friend")).map(\.id) == [toDebt.id, byCategory.id])
    // The editor only suggests categories (R-EDIT-3).
    #expect(matcher.match(description: "Dinner with a friend", accountID: F.pkoAccount.id, kind: .expense)?.id == byCategory.id)
    // A transfer rule applies to income too (money in → from the account).
    #expect(matcher.match(Self.subject("Friend paid back", kind: .income))?.id == toDebt.id)
  }

  @Test("R-IMP-8: the tester's \"any account\" lets per-account rules match; kind nil matches any category")
  func testerSemantics() {
    let scoped = Self.category(0, "orlen", F.groceries, account: F.pkoUSD.id)
    #expect(RuleMatcher.matches(scoped, description: "ORLEN 12", accountID: nil, categories: Self.categories))
    #expect(!RuleMatcher.matches(scoped, description: "ORLEN 12", accountID: F.pkoAccount.id, categories: Self.categories))
    let amount = Self.category(1, "orlen", F.groceries, amount: (.smallerThan, 50_00))
    #expect(!RuleMatcher.matches(amount, description: "ORLEN 12", accountID: nil, categories: Self.categories))
    #expect(RuleMatcher.matches(amount, description: "ORLEN 12", accountID: nil, amountMinor: 20_00, categories: Self.categories))
  }

  // MARK: Existing transactions

  static func expense(_ n: Int, _ payee: String, _ amount: Int64, account: Account = F.pkoAccount, category: AbacusDomain.Category? = nil) -> Txn {
    Txn(
      id: F.id(400 + n), type: .expense, occurredAt: F.date("2026-01-10"), accountID: account.id, amountMinor: amount,
      categoryID: category?.id, payee: payee)
  }

  @Test("R-MGMT-6: a category rule recategorises matching expenses; unchanged ones and transfers are left alone")
  func effectCategory() {
    let rule = Self.category(0, "shop", Self.food)
    let changed = RuleEffect.apply(rule, to: TxnWithLines(txn: Self.expense(1, "Shop", 10_00, category: F.groceries), lines: []), accounts: Self.accounts, categories: Self.categories)
    #expect(changed?.categoryID == Self.food.id)
    #expect(RuleEffect.apply(rule, to: TxnWithLines(txn: Self.expense(2, "Shop", 10_00, category: Self.food), lines: []), accounts: Self.accounts, categories: Self.categories) == nil)
    var transfer = Self.expense(3, "Shop", 10_00)
    transfer.type = .transfer
    transfer.toAccountID = Self.debt.id
    transfer.toAmountMinor = 10_00
    #expect(RuleEffect.apply(rule, to: TxnWithLines(txn: transfer, lines: []), accounts: Self.accounts, categories: Self.categories) == nil)
    var income = Self.expense(4, "Shop", 10_00)
    income.type = .income
    #expect(RuleEffect.apply(rule, to: TxnWithLines(txn: income, lines: []), accounts: Self.accounts, categories: Self.categories) == nil)
  }

  @Test("R-MGMT-6, D44: a transfer rule turns money out into a transfer to the account and money in into one from it")
  func effectTransfer() throws {
    let rule = Self.transfer(0, "friend", to: Self.debt)
    let out = try #require(RuleEffect.apply(
      rule, to: TxnWithLines(txn: Self.expense(1, "Friend", 50_00, category: Self.food), lines: []), accounts: Self.accounts,
      categories: Self.categories))
    #expect(out.type == .transfer)
    #expect(out.accountID == F.pkoAccount.id && out.amountMinor == 50_00)
    #expect(out.toAccountID == Self.debt.id && out.toAmountMinor == 50_00)
    #expect(out.categoryID == nil)

    var paidBack = Self.expense(2, "Friend paid back", 20_00)
    paidBack.type = .income
    let inflow = try #require(RuleEffect.apply(rule, to: TxnWithLines(txn: paidBack, lines: []), accounts: Self.accounts, categories: Self.categories))
    #expect(inflow.accountID == Self.debt.id && inflow.amountMinor == 20_00)
    #expect(inflow.toAccountID == F.pkoAccount.id && inflow.toAmountMinor == 20_00)

    // A refunded expense is money in as well.
    var refund = Self.expense(3, "Friend", 5_00)
    refund.isRefund = true
    #expect(RuleEffect.apply(rule, to: TxnWithLines(txn: refund, lines: []), accounts: Self.accounts, categories: Self.categories)?.toAccountID == F.pkoAccount.id)
    // Money in with attached records is skipped (they would move to the other account).
    let line = AttachedRecord(txnID: paidBack.id, amountMinor: 1_00)
    #expect(RuleEffect.apply(rule, to: TxnWithLines(txn: paidBack, lines: [line]), accounts: Self.accounts, categories: Self.categories) == nil)
  }

  @Test("R-MGMT-6, D44: a transfer to an account in another currency needs the original amount in that currency")
  func effectCrossCurrency() {
    let rule = Self.transfer(0, "friend", to: F.pkoUSD)
    var withOriginal = Self.expense(1, "Friend", 40_00)
    withOriginal.originalAmountMinor = 10_00
    withOriginal.originalCurrencyCode = "USD"
    let changed = RuleEffect.apply(rule, to: TxnWithLines(txn: withOriginal, lines: []), accounts: Self.accounts, categories: Self.categories)
    #expect(changed?.toAmountMinor == 10_00)
    #expect(changed?.originalAmountMinor == nil)
    #expect(RuleEffect.apply(rule, to: TxnWithLines(txn: Self.expense(2, "Friend", 40_00), lines: []), accounts: Self.accounts, categories: Self.categories) == nil)
  }

  // MARK: Import pipeline

  @Test("R-IMP-8, D44: transfer rules turn imported rows into transfers (out → to, in → from); amount conditions filter")
  func pipelineTransferRule() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount, Self.debt]
    db.categories = Self.categories
    db.rules = [
      Self.transfer(0, "anna nowak", to: Self.debt),
      Self.transfer(1, "jan kowalski", to: Self.debt, amount: (.smallerThan, 1_000_00)),
      Self.category(2, "coffee kiosk", Self.food, kind: .exactly),
    ]
    var preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let rent = try #require(preview.rows.first { $0.source.payee == "ANNA NOWAK" })
    #expect(rent.type == .transfer)
    #expect(rent.counterAccount == .existing(Self.debt.id))
    #expect(rent.counterAmountMinor == 1_500_00)
    #expect(rent.detail == "Transfer by rule “anna nowak”")
    let back = try #require(preview.rows.first { $0.source.payee == "JAN KOWALSKI" && $0.amountMinor == 120_00 })
    #expect(back.type == .transfer)
    #expect(back.counterAccount == .existing(Self.debt.id))
    // The exchange (3 650.00) is above the rule's amount.
    #expect(!preview.rows.contains { $0.amountMinor == 3_650_00 && $0.counterAccount == .existing(Self.debt.id) })
    #expect(preview.rows.filter { $0.source.payee == "COFFEE KIOSK" }.allSatisfy { $0.category == .existing(Self.food.id) })

    preview.acceptSuggestedReviewChoices()
    try await db.pipeline().commit(preview)
    let toDebt = try #require(db.txns.first { $0.payee == "ANNA NOWAK" })
    #expect(toDebt.type == .transfer && toDebt.accountID == F.pkoAccount.id && toDebt.toAccountID == Self.debt.id)
    #expect(toDebt.categoryID == nil)
    let fromDebt = try #require(db.txns.first { $0.payee == "JAN KOWALSKI" && $0.toAmountMinor == 120_00 })
    #expect(fromDebt.accountID == Self.debt.id && fromDebt.toAccountID == F.pkoAccount.id)
    #expect(db.balance(Self.debt.id) == 1_500_00 - 120_00)
    #expect(db.rules.first { $0.id == F.id(100) }?.hitCount == 1)
    #expect(db.rules.first { $0.id == F.id(101) }?.hitCount == 1)
  }

  @Test("R-IMP-8, D44: a transfer rule whose amount in the other currency is unknown gives way to the next rule")
  func pipelineTransferUnknownAmount() async throws {
    let db = FakeDB()
    db.accounts = [F.pkoAccount, F.pkoUSD]
    db.categories = Self.categories
    db.rules = [Self.transfer(0, "anna nowak", to: F.pkoUSD), Self.category(1, "anna", Self.food)]
    let preview = try await db.pipeline().preview(data: F.data("pko", "all-types"), fileName: "p.csv", targetAccountID: F.pkoAccount.id)
    let rent = try #require(preview.rows.first { $0.source.payee == "ANNA NOWAK" })
    #expect(rent.type == .expense)
    #expect(rent.category == .existing(Self.food.id))
    #expect(rent.categorySource == .rule(F.id(101), pattern: "anna"))
  }
}
