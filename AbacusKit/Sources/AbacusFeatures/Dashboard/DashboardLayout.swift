import AbacusDomain
import Foundation

/// A dashboard widget (R-HOME-6). The raw value is what `SettingKey.dashboardLayout` stores, so
/// never rename a case's raw value.
public enum DashboardWidget: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
  case netWorth
  case budget
  case expenses
  case income
  case incomeVsExpenses
  /// Shown only when the dashboard is given a debts view (R-DEBT, C14).
  case debts

  public var id: String { rawValue }

  /// Full-width widgets take a row of their own; half-width ones share a row two by two at wide
  /// widths (R-HOME-6).
  public var isFullWidth: Bool {
    switch self {
    case .netWorth, .incomeVsExpenses, .debts: true
    case .budget, .expenses, .income: false
    }
  }

  public var title: String {
    switch self {
    case .netWorth: "Net worth"
    case .budget: "Monthly budget"
    case .expenses: "Monthly expenses"
    case .income: "Monthly income"
    case .incomeVsExpenses: "Income vs expenses"
    case .debts: "Debts"
    }
  }
}

/// The order of the dashboard widgets (R-HOME-6), remembered as a JSON array of widget ids in
/// `SettingKey.dashboardLayout`. Reading is forgiving: ids this build doesn't know are dropped,
/// duplicates keep their first place, and widgets missing from the stored list (added by a later
/// version) are appended in their default order, so a new widget always shows up.
public struct DashboardLayout: Hashable, Sendable {
  public private(set) var order: [DashboardWidget]

  public static let defaultOrder: [DashboardWidget] = [
    .netWorth, .budget, .expenses, .income, .incomeVsExpenses, .debts,
  ]
  public static let `default` = DashboardLayout(order: defaultOrder)

  /// `order` completed as described above.
  public init(order: [DashboardWidget]) {
    var seen: Set<DashboardWidget> = []
    var result = order.filter { seen.insert($0).inserted }
    result += Self.defaultOrder.filter { !seen.contains($0) }
    self.order = result
  }

  /// The stored setting; nil, empty or unreadable → the default order.
  public init(stored: String?) {
    guard let data = stored?.data(using: .utf8),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    else {
      self = .default
      return
    }
    self.init(order: ids.compactMap(DashboardWidget.init(rawValue:)))
  }

  /// The setting's value: `["netWorth","budget",…]`.
  public var stored: String {
    let data = (try? JSONEncoder().encode(order.map(\.rawValue))) ?? Data("[]".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  public var isDefault: Bool { order == Self.defaultOrder }

  /// Moves `widget` to `target`'s place: the widgets in between shift by one (a drop on a
  /// widget puts the dragged one where it was). No change when either is the same or unknown.
  public mutating func move(_ widget: DashboardWidget, to target: DashboardWidget) {
    guard widget != target, let from = order.firstIndex(of: widget), let to = order.firstIndex(of: target)
    else { return }
    order.remove(at: from)
    order.insert(widget, at: to)
  }

  /// Moves `widget` one place earlier (`by: -1`) or later (`by: 1`) among `visible` widgets
  /// (keyboard and menu alternative to dragging); hidden widgets keep their places.
  public mutating func move(_ widget: DashboardWidget, by step: Int, among visible: [DashboardWidget]) {
    let shown = order.filter(visible.contains)
    guard let index = shown.firstIndex(of: widget), shown.indices.contains(index + step) else { return }
    move(widget, to: shown[index + step])
  }

  /// Rows of the widgets in order: a full-width widget alone; half-width widgets in pairs when
  /// `columns` is 2 (a half-width widget followed by a full-width one stays alone, half width).
  public static func rows(_ widgets: [DashboardWidget], columns: Int) -> [[DashboardWidget]] {
    var rows: [[DashboardWidget]] = []
    var pending: [DashboardWidget] = []
    for widget in widgets {
      if widget.isFullWidth || columns < 2 {
        if !pending.isEmpty { rows.append(pending) }
        pending = []
        rows.append([widget])
      } else {
        pending.append(widget)
        if pending.count == 2 {
          rows.append(pending)
          pending = []
        }
      }
    }
    if !pending.isEmpty { rows.append(pending) }
    return rows
  }
}
