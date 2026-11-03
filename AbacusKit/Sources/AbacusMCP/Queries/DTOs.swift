import Foundation

// What the read tools return. No IBAN or account number appears in any of these (privacy).

public struct UnconvertedDTO: Codable, Hashable, Sendable {
  /// Amounts left out of the totals because no rate was known.
  public let count: Int
  public let missingRates: [String]
}

public struct AccountDTO: Codable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let kind: String
  public let currency: String
  public let isLiability: Bool
  public let isArchived: Bool
  public let group: String?
  public let balance: MoneyDTO
}

public struct NetWorthDTO: Codable, Hashable, Sendable {
  public struct Line: Codable, Hashable, Sendable {
    public let account: String
    public let kind: String
    public let balance: MoneyDTO
    public let converted: MoneyDTO?
  }

  public struct DebtLine: Codable, Hashable, Sendable {
    public let person: String
    public let balance: MoneyDTO
    public let converted: MoneyDTO?
  }

  public let currency: String
  public let asOf: String
  public let ratesAsOf: String?
  public let assets: MoneyDTO
  public let liabilities: MoneyDTO
  public let total: MoneyDTO
  public let accounts: [Line]
  public let debtsCountedInNetWorth: [DebtLine]
  public let unconverted: UnconvertedDTO
}

public struct CategoryShareDTO: Codable, Hashable, Sendable {
  public let category: String
  public let total: MoneyDTO
  /// Percent of the breakdown's total, one decimal ("12.5"); nil when the total is not positive.
  public let sharePercent: String?
  public let subcategories: [CategoryShareDTO]
}

public struct SpendingDTO: Codable, Hashable, Sendable {
  public let kind: String
  public let from: String
  public let to: String
  public let currency: String
  public let total: MoneyDTO
  public let categories: [CategoryShareDTO]
  public let unconverted: UnconvertedDTO
}

public struct CashFlowDTO: Codable, Hashable, Sendable {
  public struct Month: Codable, Hashable, Sendable {
    public let month: String
    public let income: MoneyDTO
    public let expense: MoneyDTO
    public let net: MoneyDTO
  }

  public let from: String
  public let to: String
  public let currency: String
  public let income: MoneyDTO
  public let expense: MoneyDTO
  public let net: MoneyDTO
  public let months: [Month]
  public let unconverted: UnconvertedDTO
}

public struct BudgetDTO: Codable, Hashable, Sendable {
  public struct Line: Codable, Hashable, Sendable {
    public let category: String
    public let limit: MoneyDTO
    public let spent: MoneyDTO
    public let remaining: MoneyDTO
    public let status: String
  }

  public let month: String
  public let currency: String
  public let limit: MoneyDTO
  public let spent: MoneyDTO
  public let remaining: MoneyDTO
  public let status: String
  public let daysLeft: Int
  public let overLimitCount: Int
  public let lines: [Line]
  public let unconverted: UnconvertedDTO
}

public struct TransactionDTO: Codable, Hashable, Sendable {
  public struct Line: Codable, Hashable, Sendable {
    public let kind: String
    public let category: String?
    public let amount: MoneyDTO
    public let note: String
  }

  public let id: String
  public let date: String
  public let type: String
  public let account: String
  public let toAccount: String?
  public let amount: MoneyDTO
  public let toAmount: MoneyDTO?
  public let category: String?
  public let payee: String
  public let note: String
  public let event: String?
  public let isRefund: Bool
  public let refundOf: String?
  public let isBalanceCorrection: Bool
  public let originalAmount: MoneyDTO?
  public let source: String
  public let importBatchID: String?
  public let attachedRecords: [Line]
}

public struct TransactionSearchDTO: Codable, Hashable, Sendable {
  /// All rows matching the filters, before the cap.
  public let matching: Int
  public let returned: Int
  public let truncated: Bool
  public let transactions: [TransactionDTO]
}

public struct DebtDTO: Codable, Hashable, Sendable {
  public struct Person: Codable, Hashable, Sendable {
    public let person: String
    /// Per currency; positive = they owe the owner, negative = the owner owes them.
    public let balances: [MoneyDTO]
    public let converted: MoneyDTO?
    public let dueDay: String?
    public let isSettled: Bool
    public let countsInNetWorth: Bool
  }

  public let currency: String
  public let owedToOwner: MoneyDTO
  public let ownedByOwner: MoneyDTO
  public let people: [Person]
  public let unconverted: UnconvertedDTO
}

public struct RatesDTO: Codable, Hashable, Sendable {
  public struct Rate: Codable, Hashable, Sendable {
    public let from: String
    public let to: String
    /// `1 from = rate to`.
    public let rate: String
  }

  public let asOf: String?
  public let rates: [Rate]
}

public struct CategoryDTO: Codable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let kind: String
  public let parent: String?
  public let isArchived: Bool
}

public struct ImportBatchDTO: Codable, Hashable, Sendable {
  public let id: String
  public let source: String
  public let fileName: String
  public let importedAt: String
  public let account: String?
  public let summary: String
  public let isUndone: Bool
  public let transactions: Int
}
