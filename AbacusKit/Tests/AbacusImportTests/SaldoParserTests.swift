import AbacusDomain
import Foundation
import Testing

@testable import AbacusImport

@Suite("Saldo parser — leg patterns")
struct SaldoParserTests {
  // MARK: Format detection and errors

  @Test("R-IMP-1: canParse recognises the Saldo header, with or without BOM")
  func canParse() throws {
    #expect(SaldoParser.canParse(try SaldoFixture.data("spec-example")))
    #expect(SaldoParser.canParse(Data(("\u{FEFF}" + SaldoFixture.header + "\n").utf8)))
    #expect(SaldoParser.source == .saldo)
  }

  @Test("R-IMP-1: canParse rejects other CSVs and binary data")
  func canParseRejects() {
    #expect(!SaldoParser.canParse(Data("\"Data operacji\",\"Data waluty\",\"Typ transakcji\",\"Kwota\"\n".utf8)))
    #expect(!SaldoParser.canParse(Data("\"Transaction ID\",\"Amount\"\n".utf8)))
    #expect(!SaldoParser.canParse(Data([0xFF, 0xFE, 0x00, 0x41])))
    #expect(!SaldoParser.canParse(Data()))
  }

  @Test("R-IMP-1: a file without the required columns is not a Saldo export")
  func missingColumns() {
    #expect(throws: ImportError.unrecognisedFormat) {
      try SaldoFixture.parse(text: "\"Transaction ID\",\"Amount\"\n\"1\",\"2.00\"\n")
    }
    #expect(throws: ImportError.unrecognisedFormat) { try SaldoFixture.parse(text: "") }
  }

  @Test("R-IMP-1: invalid UTF-8 is reported as an encoding problem")
  func invalidEncoding() {
    var bytes = [UInt8](SaldoFixture.header.utf8) + [0x0A]
    bytes += [0x22, 0xC3, 0x28, 0x22]
    #expect(throws: ImportError.unreadableEncoding) { try SaldoParser().parse(Data(bytes)) }
  }

  @Test("R-IMP-SALDO-1: unreadable fields name the line")
  func malformedFields() {
    let badAmount = SaldoFixture.header + "\n"
      + #""1","2025-01-01T10:00:00","X","","Bank PLN","BANK_ACCOUNTS","0","CREDIT","1,00","PLN","","2025-01-01","""#
    #expect(throws: ImportError.malformed(line: 2, reason: "Unreadable Amount")) {
      try SaldoFixture.parse(text: badAmount)
    }
    let badSide = SaldoFixture.header + "\n"
      + #""1","2025-01-01T10:00:00","X","","Bank PLN","BANK_ACCOUNTS","0","BOTH","1.00","PLN","","2025-01-01","""#
    #expect(throws: ImportError.self) { try SaldoFixture.parse(text: badSide) }
    let badDate = SaldoFixture.header + "\n"
      + #""1","01.01.2025","X","","Bank PLN","BANK_ACCOUNTS","0","DEBIT","1.00","PLN","","2025-01-01","""#
    #expect(throws: ImportError.malformed(line: 2, reason: "Unreadable Transaction Date")) {
      try SaldoFixture.parse(text: badDate)
    }
  }

  @Test("R-IMP-SALDO-1: a header-only file parses to nothing")
  func headerOnly() throws {
    let result = try SaldoFixture.parse(text: SaldoFixture.header + "\n")
    #expect(result.rows.isEmpty)
    #expect(result.source == .saldo)
  }

  // MARK: The synthetic example of the format doc

  @Test("R-IMP-SALDO-1, R-IMP-SALDO-2, R-IMP-SALDO-3, R-CUR-4: the format doc's example")
  func specExample() throws {
    let result = try SaldoFixture.parse("spec-example")
    #expect(result.rows.count == 4)
    #expect(result.warnings.isEmpty)
    #expect(result.skippedRowCount == 0)

    let opening = try #require(result.row("1001"))
    #expect(opening.kind == .openingBalance)
    #expect(opening.account == ExternalAccount(name: "Bank UAH", currency: .UAH, kind: .bank))
    #expect(opening.amountMinor == 100_000)

    let cafe = try #require(result.row("1002"))
    #expect(cafe.kind == .expense)
    #expect(cafe.amountMinor == 44_000)
    #expect(cafe.category == ExternalCategory(name: "Eating out", kind: .expense))
    #expect(cafe.original == OriginalAmount(minorUnits: 1000, currencyCode: "EUR"))
    #expect(cafe.tag == "Trip 2025")
    #expect(cafe.payee == "CAFE")

    let topUp = try #require(result.row("1003"))
    #expect(topUp.kind == .transfer)
    #expect(topUp.account.name == "Bank USD")
    #expect(topUp.counterAccount?.name == "Wallet USD")
    #expect(topUp.amountMinor == 2000)
    #expect(topUp.counterAmountMinor == 2000)
    #expect(topUp.lines == [NormalizedLine(kind: .expense, category: ExternalCategory(name: "Fees", kind: .expense), amountMinor: 50)])

    let paired = try #require(result.row("1004"))
    #expect(paired.fingerprints == ["saldo:1004", "saldo:1005"])
    #expect(paired.kind == .transfer)
    #expect(paired.account.key == "Bank UAH|UAH")
    #expect(paired.amountMinor == 44_000)
    #expect(paired.counterAccount?.key == "Bank EUR|EUR")
    #expect(paired.counterAmountMinor == 1000)
    #expect(paired.warnings.isEmpty)
  }

  @Test("R-IMP-3: every row carries saldo:<Transaction ID> fingerprints, each id exactly once")
  func fingerprints() throws {
    let result = try SaldoFixture.parse("patterns")
    let all = result.rows.flatMap(\.fingerprints)
    #expect(Set(all).count == all.count)
    #expect(all.allSatisfy { $0.hasPrefix("saldo:20") })
    // 30 transactions: one skipped, 2029 + 2030 paired into one row.
    #expect(all.count == 29)
    #expect(result.rows.count == 28)
  }

  // MARK: Expenses and splits

  @Test("R-IMP-SALDO-1: CREDIT asset + DEBIT EXPENSES is an expense from the asset")
  func expense() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2001"))
    #expect(row.kind == .expense)
    #expect(!row.isRefund)
    #expect(row.account.key == "Bank PLN|PLN")
    #expect(row.amountMinor == 2540)
    #expect(row.category == ExternalCategory(name: "Groceries", kind: .expense))
    #expect(row.original == nil)
    #expect(row.lines.isEmpty)
    #expect(row.occurredAt == SaldoFixture.date("2025-04-01T09:15:00"))
    #expect(row.warnings.isEmpty)
  }

  @Test("R-CUR-4: an expense leg in another currency becomes the original amount")
  func expenseOriginalAmount() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2002"))
    #expect(row.amountMinor == 4310)
    #expect(row.account.currency == .PLN)
    #expect(row.original == OriginalAmount(minorUnits: 1000, currencyCode: "EUR"))
    #expect(row.occurredAt == SaldoFixture.date("2025-04-02T13:45:10.250"))
  }

  @Test("R-TX-6, R-CUR-4: two expense legs in a foreign currency split the account amount pro rata")
  func splitProRata() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2003"))
    #expect(row.kind == .expense)
    #expect(row.amountMinor == 60_001)
    #expect(row.category?.name == "Groceries")
    #expect(row.original == OriginalAmount(minorUnits: 1500, currencyCode: "EUR"))
    #expect(row.lines == [
      NormalizedLine(
        kind: .expense, category: ExternalCategory(name: "Household", kind: .expense), amountMinor: 40_000,
        original: OriginalAmount(minorUnits: 1000, currencyCode: "EUR"))
    ])
    #expect(row.amountMinor + row.lines.map(\.amountMinor).reduce(0, +) == 100_001)
    #expect(row.warnings.isEmpty)
  }

  @Test("R-TX-6: a split with one leg in the account currency gives the rest to the foreign leg")
  func splitMixedCurrencies() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2004"))
    #expect(row.amountMinor == 6000)
    #expect(row.original == nil)
    #expect(row.lines.count == 1)
    #expect(row.lines[0].amountMinor == 4000)
    #expect(row.lines[0].original == OriginalAmount(minorUnits: 900, currencyCode: "EUR"))
  }

  @Test("R-TX-6: a split over two foreign currencies is divided equally with a warning")
  func splitSeveralForeignCurrencies() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2005"))
    #expect(row.amountMinor == 1500)
    #expect(row.lines.map(\.amountMinor) == [1500])
    #expect(row.original == OriginalAmount(minorUnits: 200_000, currencyCode: "HUF"))
    #expect(row.lines[0].original == OriginalAmount(minorUnits: 2000, currencyCode: "CHF"))
    #expect(row.warnings == [SaldoWarning.estimatedSplit])
  }

  @Test("R-TX-6: a balanced split in the account currency keeps each leg's amount")
  func splitSameCurrency() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2006"))
    #expect(row.amountMinor == 3000)
    #expect(row.lines.map(\.amountMinor) == [2000])
    #expect(row.lines[0].original == nil)
    #expect(row.occurredAt == SaldoFixture.date("2025-04-06T18:20"))
  }

  @Test("R-IMP-SALDO-1: unbalanced single-currency legs keep the account amount and warn")
  func unbalancedExpense() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2023"))
    #expect(row.amountMinor == 10_000)
    #expect(row.original == nil)
    #expect(row.warnings == [SaldoWarning.unbalanced])
  }

  // MARK: Income, refunds, reversals

  @Test("R-IMP-SALDO-1: CREDIT INCOME + DEBIT asset is income")
  func income() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2012"))
    #expect(row.kind == .income)
    #expect(!row.isRefund)
    #expect(row.amountMinor == 500_000)
    #expect(row.category == ExternalCategory(name: "Salary", kind: .income))
  }

  @Test("R-TX-6: two income legs become income with an attached income record")
  func incomeSplit() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2013"))
    #expect(row.kind == .income)
    #expect(row.amountMinor == 400_000)
    #expect(row.lines == [NormalizedLine(kind: .income, category: ExternalCategory(name: "Bonus", kind: .income), amountMinor: 100_000)])
  }

  @Test("R-TX-4: DEBIT asset + CREDIT EXPENSES is a refund that keeps its expense category")
  func refund() throws {
    let result = try SaldoFixture.parse("patterns")
    let row = try #require(result.row("2014"))
    #expect(row.kind == .expense)
    #expect(row.isRefund)
    #expect(row.amountMinor == 2540)
    #expect(row.category == ExternalCategory(name: "Groceries", kind: .expense))

    let foreign = try #require(result.row("2015"))
    #expect(foreign.isRefund)
    #expect(foreign.amountMinor == 4310)
    #expect(foreign.original == OriginalAmount(minorUnits: 1000, currencyCode: "EUR"))
  }

  @Test("R-TX-4: CREDIT asset + DEBIT INCOME is an income reversal")
  func incomeReversal() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2016"))
    #expect(row.kind == .income)
    #expect(row.isRefund)
    #expect(row.amountMinor == 10_000)
    #expect(row.category?.name == "Salary")
  }

  // MARK: Transfers

  @Test("R-IMP-SALDO-1, R-ACC-2: CREDIT asset + DEBIT asset is a transfer; CASH is a cash account")
  func transferSameCurrency() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2007"))
    #expect(row.kind == .transfer)
    #expect(row.account == ExternalAccount(name: "Bank PLN", currency: .PLN, kind: .bank))
    #expect(row.counterAccount == ExternalAccount(name: "Cash PLN", currency: .PLN, kind: .cash))
    #expect(row.amountMinor == 20_000)
    #expect(row.counterAmountMinor == 20_000)
    #expect(row.category == nil)
    #expect(row.warnings.isEmpty)
  }

  @Test("R-IMP-SALDO-1: assets in different currencies make a cross-currency transfer")
  func transferCrossCurrency() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2008"))
    #expect(row.amountMinor == 430_000)
    #expect(row.counterAmountMinor == 10_000)
    #expect(row.counterAccount?.currency == .EUR)
  }

  @Test("R-TX-6: transfer + DEBIT EXPENSES in the source currency is a transfer with a fee")
  func transferFeeInSourceCurrency() throws {
    let result = try SaldoFixture.parse("patterns")
    let cross = try #require(result.row("2009"))
    #expect(cross.amountMinor == 430_000)
    #expect(cross.counterAmountMinor == 10_000)
    #expect(cross.lines == [NormalizedLine(kind: .expense, category: ExternalCategory(name: "Fees", kind: .expense), amountMinor: 1000)])

    let same = try #require(result.row("2028"))
    #expect(same.amountMinor == 10_000)
    #expect(same.counterAmountMinor == 10_000)
    #expect(same.lines.map(\.amountMinor) == [100])
    #expect(same.warnings.isEmpty)
  }

  @Test("R-TX-6, R-CUR-4: a fee in the target currency is charged pro rata in the source currency")
  func transferFeeInTargetCurrency() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2010"))
    #expect(row.counterAmountMinor == 9900)
    #expect(row.lines.count == 1)
    #expect(row.lines[0].amountMinor == 410)
    #expect(row.lines[0].original == OriginalAmount(minorUnits: 100, currencyCode: "EUR"))
    #expect(row.amountMinor == 40_590)
    #expect(row.amountMinor + row.lines[0].amountMinor == 41_000)
  }

  @Test("R-TX-6, R-CUR-4: same-currency transfer with a fee in a third currency charges the difference")
  func transferFeeInThirdCurrency() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2011"))
    #expect(row.amountMinor == 4950)
    #expect(row.counterAmountMinor == 4950)
    #expect(row.lines[0].amountMinor == 50)
    #expect(row.lines[0].original == OriginalAmount(minorUnits: 55, currencyCode: "USD"))
    #expect(row.warnings.isEmpty)
  }

  @Test("R-ACC-2: LIABILITIES are debt accounts, OTHER_ASSETS investment accounts")
  func liabilitiesAndOtherAssets() throws {
    let result = try SaldoFixture.parse("patterns")
    let lending = try #require(result.row("2018"))
    #expect(lending.kind == .transfer)
    #expect(lending.counterAccount?.kind == .debt)
    #expect(lending.counterAccount?.kind?.isLiability == true)
    let broker = try #require(result.row("2019"))
    #expect(broker.counterAccount == ExternalAccount(name: "Broker USD", currency: .USD, kind: .investment))
  }

  @Test("R-TX-6: an EXPENSES credit inside a transfer becomes an attached income record")
  func transferWithRefundLine() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2025"))
    #expect(row.kind == .transfer)
    #expect(row.amountMinor == 10_500)
    #expect(row.counterAmountMinor == 10_500)
    #expect(row.lines == [
      NormalizedLine(kind: .income, category: ExternalCategory(name: "Eating out", kind: .expense), amountMinor: 500, note: "Refund")
    ])
    #expect(row.warnings == [SaldoWarning.refundLine])
  }

  @Test("R-IMP-SALDO-1: a transfer from an account to itself is kept with a warning")
  func transferToSameAccount() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2027"))
    #expect(row.kind == .transfer)
    #expect(row.account == row.counterAccount)
    #expect(row.warnings == [SaldoWarning.sameAccount])
  }

  @Test("R-IMP-SALDO-2, R-TX-6: an outgoing half with a fee pairs into a transfer with the fee attached")
  func halfWithFeePairs() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2029"))
    #expect(row.fingerprints == ["saldo:2029", "saldo:2030"])
    #expect(row.kind == .transfer)
    #expect(row.amountMinor == 20_000)
    #expect(row.counterAccount?.key == "Cash PLN|PLN")
    #expect(row.counterAmountMinor == 20_000)
    #expect(row.lines.map(\.amountMinor) == [200])
    #expect(row.note == "Counted")
    #expect(row.occurredAt == SaldoFixture.date("2025-04-29T08:00:00"))
  }

  // MARK: Opening balances, accounts, tags, notes

  @Test("R-IMP-SALDO-3: EQUITY rows become opening balances, signed by the account leg")
  func openingBalances() throws {
    let row = try #require(try SaldoFixture.parse("patterns").row("2017"))
    #expect(row.kind == .openingBalance)
    #expect(row.account == ExternalAccount(name: "Loan PLN", currency: .PLN, kind: .debt))
    #expect(row.amountMinor == -30_000)
  }

  @Test("R-ACC-4: an archived Saldo account is created archived")
  func archivedAccount() throws {
    let result = try SaldoFixture.parse("patterns")
    let row = try #require(result.row("2020"))
    #expect(row.account.isArchived)
    #expect(row.account.name == "Old card UAH")
    #expect(try #require(result.row("2001")).account.isArchived == false)
  }

  @Test("R-ACC-2: account identity is (name, currency)")
  func accountIdentity() throws {
    let result = try SaldoFixture.parse("patterns")
    let eur = try #require(result.row("2021")).account
    let pln = try #require(result.row("2022")).account
    #expect(eur.name == pln.name)
    #expect(eur.key == "Wallet|EUR")
    #expect(pln.key == "Wallet|PLN")
    #expect(eur != pln)
  }

  @Test("R-IMP-SALDO-4: the tag passes through as an event candidate; notes keep quotes and line breaks")
  func tagsAndNotes() throws {
    let result = try SaldoFixture.parse("patterns")
    let row = try #require(result.row("2024"))
    #expect(row.tag == "Trip 2025")
    #expect(row.note == "Dinner with \"friends\"\nsecond line")
    #expect(try #require(result.row("2001")).tag == nil)
  }

  @Test("R-IMP-SALDO-4: several different tags keep the first and warn")
  func severalTags() throws {
    let text = SaldoFixture.header + "\n"
      + #""1","2025-01-01T10:00:00","X","","Bank PLN","BANK_ACCOUNTS","0","CREDIT","1.00","PLN","Trip A","2025-01-01","""# + "\n"
      + #""1","2025-01-01T10:00:00","X","","Groceries","EXPENSES","0","DEBIT","1.00","PLN","Trip B","2025-01-01","""#
    let row = try #require(try SaldoFixture.parse(text: text).row("1"))
    #expect(row.tag == "Trip A")
    #expect(row.warnings == [SaldoWarning.severalTags])
  }

  @Test("R-IMP-SALDO-1: a Parent account on a category leg becomes the category's parent")
  func parentCategory() throws {
    let text = SaldoFixture.header + "\n"
      + #""1","2025-01-01T10:00:00","X","","Bank PLN","BANK_ACCOUNTS","0","CREDIT","1.00","PLN","","2025-01-01","""# + "\n"
      + #""1","2025-01-01T10:00:00","X","Food","Groceries","EXPENSES","0","DEBIT","1.00","PLN","","2025-01-01","""#
    let row = try #require(try SaldoFixture.parse(text: text).row("1"))
    #expect(row.category == ExternalCategory(name: "Groceries", kind: .expense, parentName: "Food"))
  }

  // MARK: Skipped transactions and balances

  @Test("R-IMP-SALDO-1: an unsupported leg combination is skipped with a file warning")
  func unsupportedPattern() throws {
    let result = try SaldoFixture.parse("patterns")
    #expect(result.row("2026") == nil)
    #expect(result.skippedRowCount == 1)
    #expect(result.warnings.count == 1)
    #expect(result.warnings[0].line == 63)
    #expect(result.warnings[0].message.contains("2026"))
  }

  @Test("R-IMP-SALDO-1: an account leg in a currency Abacus accounts do not use is skipped")
  func unsupportedAccountCurrency() throws {
    let text = SaldoFixture.header + "\n"
      + #""1","2025-01-01T10:00:00","X","","Bank CHF","BANK_ACCOUNTS","0","CREDIT","1.00","CHF","","2025-01-01","""# + "\n"
      + #""1","2025-01-01T10:00:00","X","","Groceries","EXPENSES","0","DEBIT","1.00","CHF","","2025-01-01","""#
    let result = try SaldoFixture.parse(text: text)
    #expect(result.rows.isEmpty)
    #expect(result.skippedRowCount == 1)
  }

  @Test("R-ACC-3: account effects of the rows reproduce every Saldo account balance")
  func balancesMatchLegs() throws {
    let data = try SaldoFixture.data("patterns")
    let result = try SaldoParser(timeZone: SaldoFixture.utc).parse(data)
    var expected = try RowEffects.legBalances(data)
    // The skipped transaction 2026 took 10.00 PLN from Bank PLN.
    expected["Bank PLN|PLN", default: 0] += 1000
    let actual = RowEffects.balances(result.rows).filter { $0.value != 0 }
    #expect(actual == expected.filter { $0.value != 0 })

    let example = try SaldoFixture.data("spec-example")
    let exampleRows = try SaldoParser(timeZone: SaldoFixture.utc).parse(example).rows
    #expect(RowEffects.balances(exampleRows).filter { $0.value != 0 } == (try RowEffects.legBalances(example)))
  }
}
