import AbacusDomain
import AbacusImport
import Foundation

/// C41: the columns of the review row list a click on the header sorts by.
public enum ImportSortColumn: String, CaseIterable, Hashable, Sendable {
  case status, date, description, account, amount, category

  public var title: String {
    switch self {
    case .status: "Status"
    case .date: "Date"
    case .description: "Description"
    case .account: "Account"
    case .amount: "Amount"
    case .category: "Category / action"
    }
  }
}

/// C41: the sort of the review row list; no sort (nil on the model) = the file's order.
public struct ImportRowSort: Hashable, Sendable {
  public var column: ImportSortColumn
  public var ascending: Bool

  public init(column: ImportSortColumn, ascending: Bool = true) {
    self.column = column
    self.ascending = ascending
  }
}

extension ImportWizardModel {
  /// A header click: ascending, then descending, then back to the file's order. Another column
  /// starts ascending. The selection stays; Shift ranges follow the new order.
  public func toggleSort(_ column: ImportSortColumn) {
    guard let current = rowSort, current.column == column else {
      rowSort = ImportRowSort(column: column, ascending: true)
      return
    }
    rowSort = current.ascending ? ImportRowSort(column: column, ascending: false) : nil
  }

  /// The header's indicator for `column`: true = ascending, false = descending, nil = not sorted by it.
  public func sortDirection(of column: ImportSortColumn) -> Bool? {
    guard let rowSort, rowSort.column == column else { return nil }
    return rowSort.ascending
  }

  /// `rows` in the order of `rowSort`; equal keys keep the file's order (also when descending).
  func sorted(_ rows: [ImportRowItem]) -> [ImportRowItem] {
    guard let rowSort else { return rows }
    let keyed = rows.enumerated().map { (index: $0.offset, row: $0.element, key: sortKey($0.element, rowSort.column)) }
    return keyed.sorted { a, b in
      let order = a.key.compare(b.key)
      if order == .orderedSame { return a.index < b.index }
      return rowSort.ascending ? order == .orderedAscending : order == .orderedDescending
    }
    .map(\.row)
  }

  private func sortKey(_ row: ImportRowItem, _ column: ImportSortColumn) -> ImportSortKey {
    let source = preview?.row(row.id)
    switch column {
    case .status:
      return .number(Double(RowStatus.allCases.firstIndex(of: row.status) ?? 0), tie: row.statusLabel)
    case .date:
      return .number(source?.day.timeIntervalSinceReferenceDate ?? 0, tie: "")
    case .description:
      return .text(row.payee)
    case .account:
      return .text(row.account)
    case .amount:
      // Money in above zero, money out below it: ascending runs from the largest payment out.
      guard let source else { return .text(row.amount) }
      return .number(Double(source.isInflow ? source.amountMinor : -source.amountMinor), tie: "")
    case .category:
      return .text(Self.categoryText(row))
    }
  }

  /// What the Category / action column shows, as text: the picked category, else the debt, the
  /// duplicate action or the note. Rows without a category sort first when ascending.
  static func categoryText(_ row: ImportRowItem) -> String {
    if case .picker(let selection, let options, let needsCategory) = row.category {
      if needsCategory { return "" }
      return options.first { $0.choice == selection }?.label ?? ""
    }
    if let debt = row.debt { return debt }
    if let action = row.duplicateAction {
      return switch action {
      case .skip: "Skip"
      case .importAnyway: "Import anyway"
      case .link: "Link to existing"
      }
    }
    return row.note?.text ?? ""
  }
}

/// A comparable cell value: numbers (status order, day, signed amount) or text compared the way
/// Finder does (case- and diacritic-insensitive, numbers by value).
enum ImportSortKey {
  case number(Double, tie: String)
  case text(String)

  func compare(_ other: ImportSortKey) -> ComparisonResult {
    switch (self, other) {
    case (.number(let a, let ta), .number(let b, let tb)):
      if a < b { return .orderedAscending }
      if a > b { return .orderedDescending }
      return ta.localizedStandardCompare(tb)
    case (.text(let a), .text(let b)):
      return a.localizedStandardCompare(b)
    case (.number, .text): return .orderedAscending
    case (.text, .number): return .orderedDescending
    }
  }
}
