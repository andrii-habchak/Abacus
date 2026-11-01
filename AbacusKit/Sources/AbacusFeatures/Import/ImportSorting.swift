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

  /// The next sort after a click on `column`'s header: ascending, then descending, then none
  /// (the list's own order). Another column starts ascending.
  static func toggled(_ current: ImportRowSort?, _ column: ImportSortColumn) -> ImportRowSort? {
    guard let current, current.column == column else { return ImportRowSort(column: column, ascending: true) }
    return current.ascending ? ImportRowSort(column: column, ascending: false) : nil
  }

  /// `rows` in the order of `sort`; equal keys keep the given order (also when descending).
  static func sorted<Row>(_ rows: [Row], by sort: ImportRowSort?, key: (Row, ImportSortColumn) -> ImportSortKey) -> [Row] {
    guard let sort else { return rows }
    let keyed = rows.enumerated().map { (index: $0.offset, row: $0.element, key: key($0.element, sort.column)) }
    return keyed.sorted { a, b in
      let order = a.key.compare(b.key)
      if order == .orderedSame { return a.index < b.index }
      return sort.ascending ? order == .orderedAscending : order == .orderedDescending
    }
    .map(\.row)
  }
}

/// A row list whose header sorts it (C41): the import review and the "Move to another account"
/// list (C44) share the header.
@MainActor
public protocol ImportRowSorting: AnyObject {
  func toggleSort(_ column: ImportSortColumn)
  func sortDirection(of column: ImportSortColumn) -> Bool?
}

/// A row list with click / Cmd+click / Shift+click selection (C31); shared by the import review
/// and the "Move to another account" list (C44).
@MainActor
public protocol ImportRowSelecting: AnyObject {
  func select(_ id: String, mode: ImportSelectionMode)
}

extension ImportWizardModel: ImportRowSorting, ImportRowSelecting {}

extension ImportWizardModel {
  /// A header click: ascending, then descending, then back to the file's order. Another column
  /// starts ascending. The selection stays; Shift ranges follow the new order.
  public func toggleSort(_ column: ImportSortColumn) {
    rowSort = ImportRowSort.toggled(rowSort, column)
  }

  /// The header's indicator for `column`: true = ascending, false = descending, nil = not sorted by it.
  public func sortDirection(of column: ImportSortColumn) -> Bool? {
    guard let rowSort, rowSort.column == column else { return nil }
    return rowSort.ascending
  }

  /// `rows` in the order of `rowSort`; equal keys keep the file's order (also when descending).
  func sorted(_ rows: [ImportRowItem]) -> [ImportRowItem] {
    ImportRowSort.sorted(rows, by: rowSort) { sortKey($0, $1) }
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
